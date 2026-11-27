-- ============================================================================
-- 04c_advisor_indices.sql  ·  BLOQUE 3 (3/5): Advisor e índices
-- Proyecto BDA - Equipo 7 · PostgreSQL 16 (Docker)
--
-- Contenido:
--   1. Carga de trabajo para que las estadísticas tengan qué analizar
--   2. ADVISOR CASERO (PostgreSQL no tiene DBA_ADVISOR_*):
--        perf.advisor_findings         ~ DBA_ADVISOR_FINDINGS
--        perf.advisor_recommendations  ~ DBA_ADVISOR_RECOMMENDATIONS
--      Fuentes: pg_stat_statements, pg_stat_user_tables, pg_stat_user_indexes e
--      índices hipotéticos con hypopg (se prueba el costo sin crear nada).
--   3. Experimento: B-tree simple vs. compuesto vs. parcial vs. cubriente (INCLUDE)
--   4. Creación definitiva de los índices recomendados sin bloquear escrituras
--      (CREATE INDEX CONCURRENTLY, partición por partición)
--   5. Mantenimiento de índices: REINDEX, DROP/CREATE, cambio de tablespace
--   6. Medición "DESPUÉS DE ÍNDICES" y advisor de nuevo
--
-- Equivalencias Oracle -> PostgreSQL:
--   SQL Tuning Advisor / Segment Advisor  -> advisor casero (vistas perf.advisor_*)
--   ALTER INDEX ... REBUILD ONLINE        -> REINDEX (CONCURRENTLY)
--   CREATE INDEX ... ONLINE               -> CREATE INDEX CONCURRENTLY
--   Índice invisible / what-if            -> hypopg (índices hipotéticos)
--
-- Re-ejecutable: borra los índices que crea y los vuelve a crear.
-- Requiere 04a y 04b.
-- ============================================================================

\set ON_ERROR_STOP on

\echo '== 0. LIMPIEZA (re-ejecutable) =========================================='
DROP INDEX IF EXISTS rh.idx_emp_ingreso_salario;
DROP INDEX IF EXISTS rh.idx_emp_depto_salario;
DROP INDEX IF EXISTS rh.idx_asis_fecha_empleado;
DROP INDEX IF EXISTS rh.idx_variante;

\echo '== 1. CARGA DE TRABAJO ==================================================='
-- Se reinician las estadísticas y se ejecuta 3 veces cada consulta de prueba,
-- como si fuera tráfico real. La salida se descarta (\o /dev/null).
SELECT pg_stat_reset();
SELECT pg_stat_statements_reset();
\o /dev/null
SELECT sql FROM perf.consulta ORDER BY id \gexec
SELECT sql FROM perf.consulta ORDER BY id \gexec
SELECT sql FROM perf.consulta ORDER BY id \gexec
\o
-- Se fuerza la escritura de contadores de las estadísticas por-backend
SELECT pg_stat_force_next_flush();

\echo '== 2. ADVISOR CASERO ===================================================='

-- 2.1 HALLAZGOS (qué está mal). Equivalente a DBA_ADVISOR_FINDINGS.
CREATE OR REPLACE VIEW perf.advisor_findings AS
-- (a) Tablas grandes leídas secuencialmente
SELECT 'LECTURA_SECUENCIAL'::text AS tipo,
       CASE WHEN seq_tup_read > 5000000 THEN 'ALTA' ELSE 'MEDIA' END AS severidad,
       relid::regclass::text AS objeto,
       seq_scan || ' lecturas secuenciales leyeron ' || seq_tup_read || ' filas (tabla de ' || n_live_tup || ' filas)' AS detalle,
       seq_tup_read::numeric AS metrica
FROM pg_stat_user_tables
WHERE schemaname = 'rh' AND seq_scan > 0 AND n_live_tup > 50000
UNION ALL
-- (b) Consultas lentas (promedio > 100 ms)
SELECT 'CONSULTA_LENTA', CASE WHEN mean_exec_time > 1000 THEN 'ALTA' ELSE 'MEDIA' END,
       left(regexp_replace(query, '\s+', ' ', 'g'), 90),
       calls || ' ejecuciones, promedio ' || round(mean_exec_time::numeric, 1) || ' ms, máx ' || round(max_exec_time::numeric, 1) || ' ms',
       mean_exec_time::numeric
FROM pg_stat_statements
WHERE query ~ 'rh\.' AND query !~* '^\s*(explain|create|vacuum|insert|analyze|alter|reindex|drop|truncate|copy)'
  AND query !~ 'perf\.|pg_stat' AND mean_exec_time > 100
UNION ALL
-- (c) Consultas que ordenan/agregan en disco (work_mem insuficiente)
SELECT 'SORT_A_DISCO', 'MEDIA',
       left(regexp_replace(query, '\s+', ' ', 'g'), 90),
       'escribió ' || temp_blks_written || ' bloques temporales a disco en ' || calls || ' ejecuciones',
       temp_blks_written::numeric
FROM pg_stat_statements
WHERE query ~ 'rh\.' AND query !~* '^\s*(explain|create|vacuum|insert|analyze|alter|reindex|drop|truncate|copy)'
  AND query !~ 'perf\.|pg_stat' AND temp_blks_written > 0
UNION ALL
-- (d) Índices que nunca se usan (cuestan espacio y escrituras)
SELECT 'INDICE_SIN_USO', 'BAJA', s.indexrelid::regclass::text,
       'idx_scan = 0, tamaño ' || pg_size_pretty(pg_relation_size(s.indexrelid)),
       pg_relation_size(s.indexrelid)::numeric
FROM pg_stat_user_indexes s JOIN pg_index i ON i.indexrelid = s.indexrelid
WHERE s.schemaname IN ('rh','audit') AND s.idx_scan = 0 AND NOT i.indisunique AND NOT i.indisprimary
UNION ALL
-- (e) Mucha basura (tuplas muertas): requiere VACUUM
SELECT 'TUPLAS_MUERTAS', 'MEDIA', relid::regclass::text,
       n_dead_tup || ' tuplas muertas de ' || n_live_tup || ' (' || round(100.0 * n_dead_tup / n_live_tup, 1) || ' %)',
       n_dead_tup::numeric
FROM pg_stat_user_tables
WHERE schemaname IN ('rh','audit') AND n_live_tup > 1000 AND n_dead_tup > 0.1 * n_live_tup;

-- 2.2 CANDIDATOS: índices que se quiere probar de forma hipotética (umbral de recomendación: 10 % menos de costo).
DROP TABLE IF EXISTS perf.candidato_indice;
CREATE TABLE perf.candidato_indice (
    candidato_id SERIAL PRIMARY KEY,
    implementado BOOLEAN NOT NULL DEFAULT FALSE,   -- ya existe como índice real
    consulta_id  TEXT NOT NULL,   -- id de perf.consulta
    ddl          TEXT NOT NULL,       -- forma admitida por hypopg (sin nombre ni tablespace)
    motivo       TEXT NOT NULL
);
INSERT INTO perf.candidato_indice (consulta_id, ddl, motivo) VALUES
 ('Q2', 'CREATE INDEX ON rh.empleado (fecha_ingreso)',
        'Filtro por rango de fecha'),
 ('Q2', 'CREATE INDEX ON rh.empleado (fecha_ingreso, salario DESC)',
        'Filtro por fecha + orden por salario'),
 ('Q2', 'CREATE INDEX ON rh.empleado (fecha_ingreso, salario DESC) INCLUDE (empleado_id, nombre, apellido)',
        'Cubriente: permite Index Only Scan, sin visitar la tabla'),
 ('Q3', 'CREATE INDEX ON rh.asistencia (fecha, empleado_id)',
        'Filtro por rango de fecha + llave del join'),
 ('Q3', 'CREATE INDEX ON rh.asistencia (empleado_id, fecha)',
        'Llave del join primero, fecha después'),
 ('Q3', 'CREATE INDEX ON rh.empleado (depto_id, salario DESC)',
        'Filtro por departamento (subconsulta AVG y consulta externa)'),
 ('Q3', 'CREATE INDEX ON rh.empleado (depto_id, salario DESC); CREATE INDEX ON rh.asistencia (fecha, empleado_id)',
        'Combinación: los dos índices anteriores juntos (el join se beneficia de ambos)'),
 ('Q4', 'CREATE INDEX ON rh.empleado (depto_id, salario DESC) INCLUDE (activo)',
        'Entrega las filas ya ordenadas por departamento y salario: evita el sort de la ventana'),
 ('Q5', 'CREATE INDEX ON rh.empleado (depto_id, salario DESC) INCLUDE (activo)',
        'Top-N por grupo (LATERAL ... LIMIT 3): recorre el índice y se detiene a las 3 filas'),
 ('Q1', 'CREATE INDEX ON rh.empleado (apellido)',
        'CONTROL NEGATIVO: columna que la consulta no usa; el advisor debe descartarlo');

-- 2.3 RECOMENDACIONES (qué hacer). Para cada candidato: costo del plan sin y con el
--     índice HIPOTÉTICO (hypopg no crea archivos: solo engaña al planificador).
CREATE OR REPLACE FUNCTION perf.fn_advisor(p_umbral_pct NUMERIC DEFAULT 10)
RETURNS TABLE (candidato INT, consulta TEXT, ddl TEXT, motivo TEXT,
               costo_actual NUMERIC, costo_con_indice NUMERIC, mejora_pct NUMERIC, recomendacion TEXT)
LANGUAGE plpgsql AS $$
DECLARE
    c  RECORD;
    j  JSONB;
BEGIN
    FOR c IN SELECT ci.*, q.sql FROM perf.candidato_indice ci JOIN perf.consulta q ON q.id = ci.consulta_id WHERE NOT ci.implementado ORDER BY ci.candidato_id LOOP
        PERFORM hypopg_reset();
        EXECUTE 'EXPLAIN (FORMAT JSON) ' || c.sql INTO j;
        costo_actual := (j -> 0 -> 'Plan' ->> 'Total Cost')::numeric;

        -- ddl puede traer varias sentencias separadas por ';' (para probar índices en combinación)
        PERFORM hypopg_create_index(trim(stmt)) FROM unnest(string_to_array(c.ddl, ';')) AS stmt WHERE trim(stmt) <> '';
        EXECUTE 'EXPLAIN (FORMAT JSON) ' || c.sql INTO j;
        costo_con_indice := (j -> 0 -> 'Plan' ->> 'Total Cost')::numeric;
        PERFORM hypopg_reset();

        candidato  := c.candidato_id;  consulta := c.consulta_id;  ddl := c.ddl;  motivo := c.motivo;
        mejora_pct := round(100 * (costo_actual - costo_con_indice) / costo_actual, 1);
        recomendacion := CASE WHEN mejora_pct >= p_umbral_pct THEN 'CREAR' ELSE 'DESCARTAR' END;
        RETURN NEXT;
    END LOOP;
END $$;

-- Vista final: recomendaciones de índices (hypopg) + de parámetros (según estadísticas).
CREATE OR REPLACE VIEW perf.advisor_recommendations AS
SELECT 'INDICE'::text AS tipo, a.consulta AS consulta, a.ddl AS accion,
       a.costo_actual, a.costo_con_indice AS costo_con_cambio, a.mejora_pct, a.recomendacion
FROM perf.fn_advisor() a
UNION ALL
SELECT 'PARAMETRO', NULL,
       'Subir work_mem: hay ' || count(*) || ' consulta(s) que ordenan/agregan en disco',
       NULL, NULL, NULL, 'APLICAR'
FROM perf.advisor_findings WHERE tipo = 'SORT_A_DISCO' HAVING count(*) > 0
UNION ALL
SELECT 'PARAMETRO', NULL,
       'Subir shared_buffers / effective_cache_size: aciertos de caché = ' ||
       round(100.0 * blks_hit / NULLIF(blks_hit + blks_read, 0), 2) || ' %',
       NULL, NULL, NULL, 'APLICAR'
FROM pg_stat_database WHERE datname = current_database()
  AND 100.0 * blks_hit / NULLIF(blks_hit + blks_read, 0) < 99.5;

\echo '-- 2.4 HALLAZGOS (antes de cualquier cambio)'
SELECT tipo, severidad, objeto, detalle FROM perf.advisor_findings ORDER BY
    CASE severidad WHEN 'ALTA' THEN 1 WHEN 'MEDIA' THEN 2 ELSE 3 END, tipo, metrica DESC;

\echo '-- 2.5 RECOMENDACIONES (antes de cualquier cambio)'
SELECT tipo, consulta, accion, costo_actual, costo_con_cambio, mejora_pct AS "mejora_%", recomendacion
FROM perf.advisor_recommendations ORDER BY tipo, consulta, mejora_pct DESC NULLS LAST;

\echo '== 3. EXPERIMENTO: TIPOS DE ÍNDICE PARA Q2 ==============================='
-- Se crea cada variante de verdad, se mide Q2 y se borra. Interesa: tiempo de
-- construcción, tamaño en disco y tiempo de la consulta.

CREATE TABLE IF NOT EXISTS perf.variante_indice (
    variante TEXT PRIMARY KEY, definicion TEXT, construccion_ms NUMERIC,
    tamano_mb NUMERIC, q2_ms NUMERIC, q2_costo NUMERIC, nodo TEXT);
TRUNCATE perf.variante_indice;

CREATE OR REPLACE FUNCTION perf.fn_probar_variante(p_nombre TEXT, p_ddl TEXT, p_consulta TEXT DEFAULT 'Q2')
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    v_ini TIMESTAMPTZ; v_build NUMERIC; v_mb NUMERIC;
    j JSONB; mejor JSONB; ms NUMERIC; mejor_ms NUMERIC; v_sql TEXT;
    v_nodo TEXT;
BEGIN
    SELECT sql INTO v_sql FROM perf.consulta WHERE id = p_consulta;
    IF p_ddl IS NOT NULL THEN
        v_ini := clock_timestamp();
        EXECUTE p_ddl;                                                 -- CREATE INDEX idx_variante ...
        v_build := round(extract(epoch FROM clock_timestamp() - v_ini) * 1000, 1);
        SELECT round(sum(pg_relation_size(relid)) / 1048576.0, 1) INTO v_mb
        FROM pg_partition_tree('rh.idx_variante') WHERE isleaf;
        ANALYZE rh.empleado;
    END IF;
    EXECUTE 'EXPLAIN (ANALYZE, FORMAT JSON) ' || v_sql INTO j;        -- calentamiento
    FOR i IN 1..3 LOOP
        EXECUTE 'EXPLAIN (ANALYZE, FORMAT JSON) ' || v_sql INTO j;
        ms := (j -> 0 ->> 'Execution Time')::numeric;
        IF mejor_ms IS NULL OR ms < mejor_ms THEN mejor_ms := ms; mejor := j; END IF;
    END LOOP;
    -- Tipo del nodo de lectura (el primer Scan que aparezca en el plan)
    SELECT m[1] INTO v_nodo FROM regexp_matches(mejor::text, '"Node Type": "([^"]*Scan)"') m LIMIT 1;
    INSERT INTO perf.variante_indice
    VALUES (p_nombre, COALESCE(p_ddl, '(sin índice adicional)'), v_build, v_mb, mejor_ms,
            (mejor -> 0 -> 'Plan' ->> 'Total Cost')::numeric, v_nodo);
    IF p_ddl IS NOT NULL THEN EXECUTE 'DROP INDEX rh.idx_variante'; END IF;
END $$;

SELECT perf.fn_probar_variante('V0 sin índice', NULL);
SELECT perf.fn_probar_variante('V1 B-tree simple',
    'CREATE INDEX idx_variante ON rh.empleado (fecha_ingreso) TABLESPACE ts_idx');
SELECT perf.fn_probar_variante('V2 B-tree compuesto',
    'CREATE INDEX idx_variante ON rh.empleado (fecha_ingreso, salario DESC) TABLESPACE ts_idx');
SELECT perf.fn_probar_variante('V3 parcial (salario > 25000)',
    'CREATE INDEX idx_variante ON rh.empleado (fecha_ingreso, salario DESC) TABLESPACE ts_idx WHERE salario > 25000');
SELECT perf.fn_probar_variante('V4 cubriente (INCLUDE)',
    'CREATE INDEX idx_variante ON rh.empleado (fecha_ingreso, salario DESC) INCLUDE (empleado_id, nombre, apellido) TABLESPACE ts_idx');

SELECT variante, construccion_ms, tamano_mb, q2_ms, q2_costo, nodo FROM perf.variante_indice ORDER BY variante;

\echo '== 4. ÍNDICES DEFINITIVOS (CREATE INDEX CONCURRENTLY por partición) ======='

-- CREATE INDEX CONCURRENTLY no se admite directamente sobre una tabla particionada.
-- Receta oficial: (1) índice ON ONLY en la tabla padre (queda "inválido"), (2) un índice
-- CONCURRENTLY por cada partición, (3) ATTACH PARTITION; al unir todas, el padre queda válido.
-- Esta función solo GENERA las sentencias; psql las ejecuta una a una con \gexec
-- (CONCURRENTLY no puede correr dentro de una transacción ni de una función).
CREATE OR REPLACE FUNCTION perf.fn_ddl_indice_concurrente(p_tabla REGCLASS, p_indice TEXT, p_definicion TEXT)
RETURNS SETOF TEXT LANGUAGE plpgsql AS $$
DECLARE
    h RECORD;
BEGIN
    RETURN NEXT format('CREATE INDEX %I ON ONLY %s %s TABLESPACE ts_idx', p_indice, p_tabla, p_definicion);
    FOR h IN SELECT relid::regclass AS part, relid FROM pg_partition_tree(p_tabla) WHERE isleaf ORDER BY relid::regclass::text LOOP
        RETURN NEXT format('CREATE INDEX CONCURRENTLY %I ON %s %s TABLESPACE ts_idx',
                           p_indice || '_' || substr(h.part::text, strpos(h.part::text, '.') + 1), h.part, p_definicion);
        RETURN NEXT format('ALTER INDEX rh.%I ATTACH PARTITION rh.%I', p_indice,
                           p_indice || '_' || substr(h.part::text, strpos(h.part::text, '.') + 1));
    END LOOP;
END $$;

\timing on
-- i1: Q2 (rango por fecha + orden por salario). La variante cubriente se eligió en la sección 3.
SELECT perf.fn_ddl_indice_concurrente('rh.empleado', 'idx_emp_ingreso_salario',
    '(fecha_ingreso, salario DESC) INCLUDE (empleado_id, nombre, apellido)') \gexec
-- i2: Q3 y Q4 (por departamento, ya ordenado por salario)
SELECT perf.fn_ddl_indice_concurrente('rh.empleado', 'idx_emp_depto_salario',
    '(depto_id, salario DESC) INCLUDE (activo)') \gexec
-- i3: Q3 (asistencia por fecha y empleado)
SELECT perf.fn_ddl_indice_concurrente('rh.asistencia', 'idx_asis_fecha_empleado',
    '(fecha, empleado_id)') \gexec
\timing off

\echo '-- 4.1 Verificación: todos los índices válidos, en ts_idx, con su tamaño'
SELECT c.relname AS indice, i.indisvalid AS valido, COALESCE(t.spcname, 'pg_default') AS tablespace,
       pg_size_pretty(pg_relation_size(c.oid)) AS tamano
FROM pg_index i
JOIN pg_class c ON c.oid = i.indexrelid
JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'rh'
LEFT JOIN pg_tablespace t ON t.oid = c.reltablespace
WHERE c.relname ~ '^idx_(emp|asis)_' AND c.relname !~ '_(empleado|asistencia)_'
ORDER BY c.relname;

SELECT c.relname AS indice_particion, i.indisvalid AS valido, COALESCE(t.spcname, 'pg_default') AS tablespace
FROM pg_index i
JOIN pg_class c ON c.oid = i.indexrelid
JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'rh'
LEFT JOIN pg_tablespace t ON t.oid = c.reltablespace
WHERE c.relname ~ '^idx_emp_ingreso_salario_' ORDER BY 1;

\echo '== 5. MANTENIMIENTO DE ÍNDICES =========================================='
\echo '-- 5.1 Tamaño antes de reconstruir (una partición)'
SELECT pg_size_pretty(pg_relation_size('rh.idx_emp_ingreso_salario_empleado_hasta_2019')) AS tamano;
\echo '-- 5.2 REINDEX CONCURRENTLY: reconstruye sin bloquear lecturas ni escrituras'
\timing on
REINDEX INDEX CONCURRENTLY rh.idx_emp_ingreso_salario_empleado_hasta_2019;
\timing off
SELECT pg_size_pretty(pg_relation_size('rh.idx_emp_ingreso_salario_empleado_hasta_2019')) AS tamano_despues;

\echo '-- 5.3 Cambiar un índice de tablespace (ej. mover un índice de partición fría a ts_cold)'
ALTER INDEX rh.idx_emp_ingreso_salario_empleado_hasta_2019 SET TABLESPACE ts_cold;
SELECT c.relname, t.spcname FROM pg_class c JOIN pg_tablespace t ON t.oid = c.reltablespace
WHERE c.relname = 'idx_emp_ingreso_salario_empleado_hasta_2019';
ALTER INDEX rh.idx_emp_ingreso_salario_empleado_hasta_2019 SET TABLESPACE ts_idx;   -- se devuelve a ts_idx

\echo '-- 5.4 Modificar un índice = DROP + CREATE (PostgreSQL no tiene ALTER INDEX para columnas)'
DROP INDEX rh.idx_emp_depto_salario;                 -- borra el padre y todas sus particiones
SELECT perf.fn_ddl_indice_concurrente('rh.empleado', 'idx_emp_depto_salario',
    '(depto_id, salario DESC) INCLUDE (activo)') \gexec

VACUUM (ANALYZE) rh.empleado;
VACUUM (ANALYZE) rh.asistencia;

\echo '== 6. MEDICIÓN "DESPUÉS DE ÍNDICES" ====================================='
SELECT perf.fn_medir('indices');

SELECT b.concepto AS consulta,
       b.valor AS ms_antes, i.valor AS ms_despues,
       round(b.valor / i.valor, 1) AS veces_mas_rapido,
       (b.extra ->> 'costo')::numeric AS costo_antes, (i.extra ->> 'costo')::numeric AS costo_despues,
       i.extra ->> 'nodo_raiz' AS nodo_raiz
FROM perf.medicion b JOIN perf.medicion i ON i.concepto = b.concepto AND i.etapa = 'indices'
WHERE b.etapa = 'base' ORDER BY 1;

\echo '-- 6.1 Planes nuevos de las consultas que cambiaron'
SELECT stmt FROM (
    SELECT id, 1 AS orden, format('SELECT %L AS consulta', id || ' · ' || nombre) AS stmt FROM perf.consulta
    UNION ALL
    SELECT id, 2, 'EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF) ' || sql FROM perf.consulta
) x ORDER BY id, orden \gexec

\echo '-- 6.2 ¿Se usan los índices nuevos? (pg_stat_user_indexes)'
SELECT regexp_replace(indexrelname, '_(empleado|asistencia)_.*$', '') AS indice, sum(idx_scan) AS usos
FROM pg_stat_user_indexes WHERE schemaname = 'rh' AND indexrelname ~ '^idx_(emp|asis)_'
GROUP BY 1 ORDER BY 1;

\echo '-- 6.3 El advisor ahora: se marcan como implementados los candidatos creados y se vuelve a evaluar el resto'
UPDATE perf.candidato_indice SET implementado = TRUE
WHERE ddl IN ('CREATE INDEX ON rh.empleado (fecha_ingreso, salario DESC) INCLUDE (empleado_id, nombre, apellido)',
              'CREATE INDEX ON rh.asistencia (fecha, empleado_id)',
              'CREATE INDEX ON rh.empleado (depto_id, salario DESC)',
              'CREATE INDEX ON rh.empleado (depto_id, salario DESC); CREATE INDEX ON rh.asistencia (fecha, empleado_id)',
              'CREATE INDEX ON rh.empleado (depto_id, salario DESC) INCLUDE (activo)');
SELECT tipo, consulta, accion, costo_actual, costo_con_cambio, mejora_pct AS "mejora_%", recomendacion
FROM perf.advisor_recommendations WHERE tipo = 'INDICE' ORDER BY consulta, mejora_pct DESC NULLS LAST;
