-- ============================================================================
-- 04e_comparativo.sql  ·  BLOQUE 3 (5/5): Medición final y comparativo antes/después
-- Proyecto BDA - Equipo 7 · PostgreSQL 16 (Docker)
--
-- Requiere: 04a..04d ejecutados y `make restart` (para que shared_buffers aplique).
-- Mide las mismas 4 consultas con índices + parámetros ajustados y arma el comparativo
-- de las tres etapas: base (solo PK) -> índices -> índices + parámetros.
-- ============================================================================

\set ON_ERROR_STOP on

\echo '== 1. PARÁMETROS VIGENTES (tras el reinicio) ============================'
SELECT p.nombre, p.valor AS antes, current_setting(p.nombre) AS despues,
       (SELECT NOT pending_restart FROM pg_settings WHERE name = p.nombre) AS aplicado
FROM perf.parametro p WHERE p.etapa = 'antes' ORDER BY 1;

DO $$ BEGIN
    IF current_setting('shared_buffers') <> '512MB' THEN
        RAISE EXCEPTION 'shared_buffers sigue en % : falta ejecutar make restart', current_setting('shared_buffers');
    END IF;
END $$;

\echo '== 2. MEDICIÓN "PARÁMETROS" (índices + parámetros ajustados) ============'
SELECT perf.fn_medir('parametros');

\echo '== 3. COMPARATIVO ANTES / DESPUÉS ======================================='
SELECT b.concepto AS consulta, q.nombre,
       b.valor  AS ms_base,
       i.valor  AS ms_indices,
       p.valor  AS ms_final,
       round(b.valor / p.valor, 1) AS veces_mejor
FROM perf.medicion b
JOIN perf.medicion i ON i.concepto = b.concepto AND i.etapa = 'indices'
JOIN perf.medicion p ON p.concepto = b.concepto AND p.etapa = 'parametros'
JOIN perf.consulta q ON q.id = b.concepto
WHERE b.etapa = 'base' ORDER BY 1;

\echo '-- 3.1 Costo estimado y buffers (I/O lógico) por etapa'
SELECT m.concepto AS consulta, m.etapa,
       (m.extra ->> 'costo')::numeric AS costo_plan,
       (m.extra ->> 'buffers_hit')::bigint + (m.extra ->> 'buffers_read')::bigint AS buffers_totales,
       (m.extra ->> 'buffers_read')::bigint AS leidos_de_disco,
       m.extra ->> 'nodo_raiz' AS nodo_raiz
FROM perf.medicion m WHERE m.concepto ~ '^Q[0-9]+$'
ORDER BY m.concepto, CASE m.etapa WHEN 'base' THEN 1 WHEN 'indices' THEN 2 ELSE 3 END;

\echo '-- 3.2 Carga masiva (50,000 filas) por método'
SELECT concepto, valor AS ms, round(50000 / (valor / 1000)) AS filas_por_seg
FROM perf.medicion WHERE etapa = 'carga' AND concepto ~ '_50k$' ORDER BY medicion_id;

\echo '-- 3.3 Variantes de índice para Q2'
SELECT variante, construccion_ms, tamano_mb, q2_ms, nodo FROM perf.variante_indice ORDER BY variante;

\echo '== 4. PLANES FINALES (con índices y parámetros ajustados) ================'
-- Compárense con evidencias/04b_explain_base.txt: ya no hay "Sort Method: external merge" (disco).
SELECT stmt FROM (
    SELECT id, 1 AS orden, format('SELECT %L AS consulta', id || ' · ' || nombre) AS stmt FROM perf.consulta
    UNION ALL
    SELECT id, 2, 'EXPLAIN (ANALYZE, BUFFERS, COSTS OFF) ' || sql FROM perf.consulta
) x ORDER BY id, orden \gexec
