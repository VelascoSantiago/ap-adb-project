-- ============================================================================
-- 04b_explain_base.sql  ·  BLOQUE 3 (2/5): Línea base de rendimiento (ANTES)
-- Proyecto BDA - Equipo 7 · PostgreSQL 16 (Docker)
--
-- Contenido:
--   1. Las cinco consultas complejas de prueba (se guardan en perf.consulta)
--   2. perf.fn_medir(): ejecuta EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) y guarda tiempo,
--      costo y buffers en perf.medicion  -> base del comparativo antes/después
--   3. Medición ANTES (solo PK, parámetros por defecto) y planes completos
--
-- Equivalencias Oracle -> PostgreSQL:
--   EXPLAIN PLAN FOR ... + DBMS_XPLAN.DISPLAY -> EXPLAIN (ANALYZE, BUFFERS)
--   (Oracle muestra el plan estimado; con ANALYZE PostgreSQL ejecuta y muestra el real.)
--
-- Re-ejecutable (solo borra la etapa 'base'). Requiere 04a. Debe correrse ANTES de 04c.
-- ============================================================================

\set ON_ERROR_STOP on

\echo '== 1. CONSULTAS DE PRUEBA ==============================================='

CREATE TABLE IF NOT EXISTS perf.consulta (
    id           TEXT PRIMARY KEY,
    nombre       TEXT NOT NULL,
    descripcion  TEXT NOT NULL,
    sql          TEXT NOT NULL
);
TRUNCATE perf.consulta CASCADE;

INSERT INTO perf.consulta (id, nombre, descripcion, sql) VALUES
('Q1', 'Join + agregación',
 'Nómina y salario promedio por departamento y puesto (empleados activos desde 2020): join de 3 tablas, GROUP BY, HAVING y ORDER BY.',
 $q$SELECT d.nombre AS departamento, r.nombre AS puesto,
       COUNT(*) AS empleados, ROUND(AVG(e.salario), 2) AS salario_promedio, SUM(e.salario) AS nomina
FROM rh.empleado e
JOIN rh.departamento d ON d.depto_id = e.depto_id
JOIN rh.rol_laboral  r ON r.rol_id   = e.rol_id
WHERE e.activo AND e.fecha_ingreso >= DATE '2020-01-01'
GROUP BY d.nombre, r.nombre
HAVING COUNT(*) > 100
ORDER BY nomina DESC$q$),
('Q2', 'Rango por fecha + partition pruning',
 'Los 50 mejor pagados que ingresaron en el primer semestre de 2025: el filtro por fecha permite podar particiones; ORDER BY ... LIMIT.',
 $q$SELECT empleado_id, nombre, apellido, salario, fecha_ingreso
FROM rh.empleado
WHERE fecha_ingreso BETWEEN DATE '2025-01-01' AND DATE '2025-06-30'
  AND salario > 30000
ORDER BY salario DESC
LIMIT 50$q$),
('Q3', 'Subconsulta + join con asistencia',
 'Empleados de Sistemas con salario sobre el promedio de su departamento, ordenados por asistencias de dos semanas: subconsulta escalar + join + agregación sobre la tabla de 1 M de filas.',
 $q$SELECT e.empleado_id, e.nombre, e.apellido, e.salario, COUNT(*) AS asistencias
FROM rh.empleado e
JOIN rh.asistencia a ON a.empleado_id = e.empleado_id
                    AND a.fecha BETWEEN DATE '2026-11-02' AND DATE '2026-11-13'
WHERE e.depto_id = 1
  AND e.salario > (SELECT AVG(salario) FROM rh.empleado WHERE depto_id = 1)
GROUP BY e.empleado_id, e.nombre, e.apellido, e.salario
ORDER BY asistencias DESC, e.salario DESC
LIMIT 20$q$),
('Q4', 'Función de ventana',
 'Los 3 salarios más altos de cada departamento entre activos: RANK() OVER (PARTITION BY ... ORDER BY ...) y filtro sobre la ventana.',
 $q$SELECT *
FROM (SELECT e.depto_id, e.empleado_id, e.salario,
             RANK() OVER (PARTITION BY e.depto_id ORDER BY e.salario DESC) AS posicion
      FROM rh.empleado e
      WHERE e.activo) t
WHERE posicion <= 3
ORDER BY depto_id, posicion, empleado_id$q$),
('Q5', 'Reescritura de Q4 con LATERAL (top-N por grupo)',
 'Mismo resultado que Q4 (los 3 mejor pagados por departamento) pero pidiendo solo 3 filas por grupo: con el índice (depto_id, salario DESC) lee ~18 filas en vez de 460 mil. Muestra que a veces reescribir la consulta rinde más que el índice solo.',
 $q$SELECT d.depto_id, t.empleado_id, t.salario
FROM rh.departamento d
CROSS JOIN LATERAL (SELECT e.empleado_id, e.salario
                    FROM rh.empleado e
                    WHERE e.depto_id = d.depto_id AND e.activo
                    ORDER BY e.salario DESC, e.empleado_id
                    LIMIT 3) t
ORDER BY d.depto_id, t.salario DESC, t.empleado_id$q$);

SELECT id, nombre FROM perf.consulta ORDER BY id;

\echo '== 2. FUNCIÓN DE MEDICIÓN ==============================================='

-- Ejecuta cada consulta (1 calentamiento + p_reps mediciones) y guarda la MEJOR repetición.
-- Se usa EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) y se extrae del JSON:
--   Execution Time (ms), costo estimado total, buffers leídos de caché (hit) y de disco (read).
CREATE OR REPLACE FUNCTION perf.fn_medir(p_etapa TEXT, p_reps INT DEFAULT 3) RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE
    c       RECORD;
    j       JSONB;
    mejor   JSONB;
    ms      NUMERIC;
    mejor_ms NUMERIC;
BEGIN
    DELETE FROM perf.medicion WHERE etapa = p_etapa AND concepto ~ '^Q[0-9]+$';
    FOR c IN SELECT * FROM perf.consulta ORDER BY id LOOP
        EXECUTE 'EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) ' || c.sql INTO j;      -- calentamiento (caché)
        mejor_ms := NULL;
        FOR i IN 1..p_reps LOOP
            EXECUTE 'EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) ' || c.sql INTO j;
            ms := (j -> 0 ->> 'Execution Time')::numeric;
            IF mejor_ms IS NULL OR ms < mejor_ms THEN mejor_ms := ms; mejor := j; END IF;
        END LOOP;
        INSERT INTO perf.medicion (etapa, concepto, valor, extra)
        VALUES (p_etapa, c.id, mejor_ms,
                jsonb_build_object(
                    'costo',        (mejor -> 0 -> 'Plan' ->> 'Total Cost')::numeric,
                    'planificacion_ms', (mejor -> 0 ->> 'Planning Time')::numeric,
                    'buffers_hit',  (mejor -> 0 -> 'Plan' ->> 'Shared Hit Blocks')::bigint,
                    'buffers_read', (mejor -> 0 -> 'Plan' ->> 'Shared Read Blocks')::bigint,
                    'nodo_raiz',    mejor -> 0 -> 'Plan' ->> 'Node Type'));
    END LOOP;
END $$;

\echo '== 3. MEDICIÓN "ANTES" (solo claves primarias, parámetros por defecto) ==='

\echo '-- 3.1 Índices existentes (solo PK/UNIQUE) y parámetros vigentes'
SELECT tablename, indexname FROM pg_indexes WHERE schemaname = 'rh' AND tablename ~ '^(empleado|asistencia)$' ORDER BY 1, 2;
SELECT name, setting, unit FROM pg_settings
WHERE name IN ('block_size','shared_buffers','work_mem','maintenance_work_mem','effective_cache_size','random_page_cost')
ORDER BY name;

SELECT perf.fn_medir('base');

\echo '-- 3.2 Resultado (mejor de 3 repeticiones, caché caliente)'
SELECT concepto AS consulta, valor AS ms,
       (extra ->> 'costo')::numeric AS costo_plan,
       (extra ->> 'buffers_hit')::bigint AS buffers_hit, (extra ->> 'buffers_read')::bigint AS buffers_read,
       extra ->> 'nodo_raiz' AS nodo_raiz
FROM perf.medicion WHERE etapa = 'base' ORDER BY concepto;

\echo '== 4. PLANES COMPLETOS (EXPLAIN ANALYZE, BUFFERS) ========================'
-- Por cada consulta: una fila de título y su EXPLAIN. \gexec ejecuta cada resultado como sentencia.
SELECT stmt FROM (
    SELECT id, 1 AS orden, format('SELECT %L AS consulta', id || ' · ' || nombre || ' — ' || descripcion) AS stmt FROM perf.consulta
    UNION ALL
    SELECT id, 2, 'EXPLAIN (ANALYZE, BUFFERS) ' || sql FROM perf.consulta
) x ORDER BY id, orden \gexec
