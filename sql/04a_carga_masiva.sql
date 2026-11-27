-- ============================================================================
-- 04a_carga_masiva.sql  ·  BLOQUE 3 (1/5): Inserción masiva
-- Proyecto BDA - Equipo 7 · PostgreSQL 16 (Docker)
--
-- Contenido:
--   1. Esquema perf: tablas donde se guardan las mediciones (base del comparativo)
--   2. Dos formas de cargar 50,000 filas y su costo:
--        A) PL/pgSQL fila por fila (bucle)      -> equivalente al PL/SQL del enunciado
--        B) INSERT ... SELECT generate_series() -> una sola sentencia (set-based)
--        C) igual que B pero sin el trigger de auditoría
--      Las tres se miden dentro de una transacción que se revierte (ROLLBACK),
--      así la comparación es justa (mismo estado inicial) y no deja basura.
--   3. Carga definitiva: 500,000 empleados + ~1 millón de asistencias
--   4. Estadísticas (ANALYZE) y tamaños
--
-- Equivalencias Oracle -> PostgreSQL:
--   Bloque anónimo PL/SQL con FOR ... LOOP -> función PL/pgSQL con FOR ... LOOP
--   INSERT /*+ APPEND */ ... SELECT        -> INSERT ... SELECT generate_series()
--   DBMS_UTILITY.GET_TIME                  -> clock_timestamp()
--
-- Re-ejecutable: si ya hay datos masivos, no vuelve a cargar (para rehacer: 02, 03, 04a).
-- ============================================================================

\set ON_ERROR_STOP on
\timing off

\echo '== 1. ESQUEMA perf (mediciones) ========================================='

CREATE SCHEMA IF NOT EXISTS perf;
COMMENT ON SCHEMA perf IS 'Mediciones de rendimiento, consultas de prueba y advisor casero';

-- Una fila por medición: permite construir el comparativo antes/después.
CREATE TABLE IF NOT EXISTS perf.medicion (
    medicion_id  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    etapa        TEXT        NOT NULL,   -- carga | base | indices | parametros
    concepto     TEXT        NOT NULL,   -- p. ej. 'Q1' o 'carga_bucle_50k'
    valor        NUMERIC     NOT NULL,   -- milisegundos
    extra        JSONB,                  -- costo del plan, buffers, etc.
    fecha        TIMESTAMPTZ NOT NULL DEFAULT now()
);

SELECT (SELECT count(*) FROM rh.empleado) > 1000 AS ya_cargado \gset
\if :ya_cargado
\echo 'Ya hay datos masivos cargados: no se vuelve a cargar (para rehacer: ejecutar 02, 03 y 04a).'
\else

-- Carga nueva: se reinician las mediciones de todas las etapas.
TRUNCATE perf.medicion RESTART IDENTITY;
-- ...y los parámetros vuelven a los valores de fábrica para que la línea base sea honesta
-- (shared_buffers requiere reiniciar: make restart; sin ese paso solo se aprecian los demás).
DROP TABLE IF EXISTS perf.parametro;
ALTER SYSTEM RESET shared_buffers;       ALTER SYSTEM RESET work_mem;
ALTER SYSTEM RESET maintenance_work_mem; ALTER SYSTEM RESET effective_cache_size;
ALTER SYSTEM RESET random_page_cost;
SELECT pg_reload_conf();

\echo '== 2. FUNCIONES DE CARGA ================================================'

-- Datos de apoyo para generar nombres realistas
-- (se usan arreglos en vez de tablas para no ensuciar el esquema)

-- A) Fila por fila: un INSERT por iteración, con una consulta de rol por fila.
--    Cada INSERT dispara los triggers de validación y de auditoría.
CREATE OR REPLACE FUNCTION perf.fn_carga_bucle(p_n INT, p_prefijo TEXT) RETURNS NUMERIC
LANGUAGE plpgsql AS $$
DECLARE
    v_ini    TIMESTAMPTZ := clock_timestamp();
    v_rol    rh.rol_laboral%ROWTYPE;
    v_nombres TEXT[] := ARRAY['Juan','María','Carlos','Ana','Luis','Sofía','Diego','Laura','Pablo','Elena',
                              'Jorge','Valeria','Andrés','Camila','Iván','Daniela','Mario','Paula','Raúl','Marta'];
    v_apell   TEXT[] := ARRAY['García','Hernández','López','Martínez','González','Pérez','Rodríguez','Sánchez',
                              'Ramírez','Flores','Torres','Rivera','Gómez','Díaz','Cruz','Morales','Ortiz','Reyes','Vargas','Silva'];
    v_r       DOUBLE PRECISION;
    v_rol_id  INT;
BEGIN
    FOR i IN 1..p_n LOOP
        v_r := random();
        v_rol_id := CASE WHEN v_r < 0.01 THEN 1 WHEN v_r < 0.05 THEN 2 WHEN v_r < 0.30 THEN 3
                         WHEN v_r < 0.60 THEN 4 WHEN v_r < 0.75 THEN 5 ELSE 6 END;
        SELECT * INTO v_rol FROM rh.rol_laboral WHERE rol_id = v_rol_id;

        INSERT INTO rh.empleado (nombre, apellido, email, depto_id, rol_id, salario, fecha_ingreso, activo, nivel_confidencialidad)
        VALUES (v_nombres[1 + floor(random() * 20)::int],
                v_apell[1 + floor(random() * 20)::int],
                'emp' || i || '.' || p_prefijo || '@carga.mx',
                1 + floor(power(random(), 1.5) * 6)::int,
                v_rol_id,
                round((v_rol.salario_min + random() * (v_rol.salario_max - v_rol.salario_min))::numeric, 2),
                DATE '2012-01-01' + floor(random() * (DATE '2026-11-20' - DATE '2012-01-01'))::int,
                random() > 0.08,
                v_rol.nivel_confidencialidad);
    END LOOP;
    RETURN round(extract(epoch FROM clock_timestamp() - v_ini) * 1000, 1);
END $$;

-- B/C) Una sola sentencia: el motor genera las N filas y las inserta en bloque.
CREATE OR REPLACE FUNCTION perf.fn_carga_set(p_n INT, p_prefijo TEXT) RETURNS NUMERIC
LANGUAGE plpgsql AS $$
DECLARE
    v_ini TIMESTAMPTZ := clock_timestamp();
BEGIN
    INSERT INTO rh.empleado (nombre, apellido, email, depto_id, rol_id, salario, fecha_ingreso, activo, nivel_confidencialidad)
    SELECT (ARRAY['Juan','María','Carlos','Ana','Luis','Sofía','Diego','Laura','Pablo','Elena',
                  'Jorge','Valeria','Andrés','Camila','Iván','Daniela','Mario','Paula','Raúl','Marta'])[1 + floor(random() * 20)::int],
           (ARRAY['García','Hernández','López','Martínez','González','Pérez','Rodríguez','Sánchez','Ramírez','Flores',
                  'Torres','Rivera','Gómez','Díaz','Cruz','Morales','Ortiz','Reyes','Vargas','Silva'])[1 + floor(random() * 20)::int],
           'emp' || g.i || '.' || p_prefijo || '@carga.mx',
           1 + floor(power(random(), 1.5) * 6)::int,                 -- departamentos con tamaños desiguales
           x.rol_id,
           round((r.salario_min + random() * (r.salario_max - r.salario_min))::numeric, 2),
           DATE '2012-01-01' + floor(random() * (DATE '2026-11-20' - DATE '2012-01-01'))::int,
           random() > 0.08,                                          -- ~8 % inactivos
           r.nivel_confidencialidad
    FROM generate_series(1, p_n) AS g(i)
    CROSS JOIN LATERAL (SELECT CASE WHEN rr < 0.01 THEN 1 WHEN rr < 0.05 THEN 2 WHEN rr < 0.30 THEN 3
                                    WHEN rr < 0.60 THEN 4 WHEN rr < 0.75 THEN 5 ELSE 6 END AS rol_id
                        FROM (SELECT random() + g.i * 0 AS rr) q) x     -- g.i fuerza un random() por fila
    JOIN rh.rol_laboral r ON r.rol_id = x.rol_id;
    RETURN round(extract(epoch FROM clock_timestamp() - v_ini) * 1000, 1);
END $$;

\echo '== 2.1 MEDICIÓN: 50,000 filas por tres métodos (cada una con ROLLBACK) ==='

\echo '-- A) PL/pgSQL fila por fila, con triggers (validación + auditoría)'
BEGIN;
SELECT perf.fn_carga_bucle(50000, 'a') AS ms \gset a_
ROLLBACK;
\echo 'A) ms =' :a_ms

\echo '-- B) INSERT ... SELECT generate_series, con triggers'
BEGIN;
SELECT perf.fn_carga_set(50000, 'b') AS ms \gset b_
ROLLBACK;
\echo 'B) ms =' :b_ms

\echo '-- C) INSERT ... SELECT generate_series, sin el trigger de auditoría'
BEGIN;
ALTER TABLE rh.empleado DISABLE TRIGGER trg_auditar_empleado;
SELECT perf.fn_carga_set(50000, 'c') AS ms \gset c_
ROLLBACK;     -- el ROLLBACK también deshace el DISABLE TRIGGER
\echo 'C) ms =' :c_ms

INSERT INTO perf.medicion (etapa, concepto, valor, extra) VALUES
    ('carga', 'A_bucle_con_triggers_50k',  :a_ms, '{"filas":50000,"metodo":"PL/pgSQL fila por fila"}'),
    ('carga', 'B_set_con_triggers_50k',    :b_ms, '{"filas":50000,"metodo":"INSERT SELECT generate_series"}'),
    ('carga', 'C_set_sin_auditoria_50k',   :c_ms, '{"filas":50000,"metodo":"INSERT SELECT, sin trigger de auditoría"}');

\echo '-- Resumen de la comparación (50,000 filas)'
SELECT concepto,
       valor                                                   AS ms,
       round(50000 / (valor / 1000))                           AS filas_por_seg,
       round(valor / (SELECT valor FROM perf.medicion WHERE concepto = 'C_set_sin_auditoria_50k'
                      ORDER BY medicion_id DESC LIMIT 1), 1)   AS veces_vs_mejor
FROM perf.medicion WHERE etapa = 'carga' AND medicion_id > (SELECT max(medicion_id) - 3 FROM perf.medicion)
ORDER BY medicion_id;

\echo '== 3. CARGA DEFINITIVA: 500,000 empleados ==============================='
-- Se desactiva el trigger de auditoría durante la carga inicial (es una carga masiva,
-- no cambios de negocio); el de validación de salario sigue activo.
ALTER TABLE rh.empleado DISABLE TRIGGER trg_auditar_empleado;
SELECT perf.fn_carga_set(500000, 'x') AS ms \gset d_
ALTER TABLE rh.empleado ENABLE TRIGGER trg_auditar_empleado;
\echo 'Carga de 500,000 empleados, ms =' :d_ms
INSERT INTO perf.medicion (etapa, concepto, valor, extra)
VALUES ('carga', 'D_carga_definitiva_500k', :d_ms, '{"filas":500000}');

\echo '== 3.1 ASISTENCIA: ~1 millón de filas (40,000 empleados x 25 días hábiles)'
\timing on
INSERT INTO rh.asistencia (empleado_id, fecha, hora_entrada, hora_salida)
SELECT e.empleado_id, d::date,
       TIME '07:30' + make_interval(mins => floor(random() * 120)::int),
       TIME '16:30' + make_interval(mins => floor(random() * 180)::int)
FROM (SELECT empleado_id FROM rh.empleado WHERE activo ORDER BY empleado_id LIMIT 40000) e
CROSS JOIN generate_series(DATE '2026-10-12', DATE '2026-11-13', INTERVAL '1 day') AS d
WHERE extract(isodow FROM d) < 6;
\timing off

\echo '== 4. ESTADÍSTICAS Y TAMAÑOS ============================================'
VACUUM (ANALYZE) rh.empleado;
VACUUM (ANALYZE) rh.asistencia;

SELECT 'rh.empleado'   AS tabla, count(*) AS filas FROM rh.empleado
UNION ALL SELECT 'rh.asistencia', count(*) FROM rh.asistencia;

\echo '-- Filas y tamaño por partición (carga repartida entre tablespaces)'
SELECT c.relname AS particion, COALESCE(t.spcname, 'pg_default') AS tablespace,
       c.reltuples::bigint AS filas_aprox,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS tamano_total
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'rh'
LEFT JOIN pg_tablespace t ON t.oid = c.reltablespace
WHERE c.relkind = 'r' AND (c.relname LIKE 'empleado\_%' OR c.relname LIKE 'asistencia\_p%')
ORDER BY c.relname;

\endif

\echo '-- Mediciones de carga registradas'
SELECT concepto, valor AS ms, extra ->> 'metodo' AS metodo FROM perf.medicion WHERE etapa = 'carga' ORDER BY medicion_id;
