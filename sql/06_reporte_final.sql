-- ============================================================================
-- 06_reporte_final.sql  ·  BLOQUE 5: Reporte consolidado antes/después
-- Proyecto BDA - Equipo 7 · PostgreSQL 16 (Docker)
--
-- Solo LEE lo medido en los bloques 3 y 4 (perf.medicion, perf.parametro, perf.variante_indice,
-- mant.*) y lo presenta en un solo lugar. Crea la vista perf.v_comparativo (útil para la demo).
-- Requiere: 04a..04e y 05 ejecutados. No modifica datos.
-- ============================================================================

\set ON_ERROR_STOP on

CREATE OR REPLACE VIEW perf.v_comparativo AS
SELECT c.id AS consulta, c.nombre,
       b.valor  AS ms_base,
       i.valor  AS ms_indices,
       p.valor  AS ms_final,
       round(b.valor / p.valor, 1)                     AS veces_mejor,
       (b.extra ->> 'costo')::numeric                  AS costo_base,
       (p.extra ->> 'costo')::numeric                  AS costo_final,
       (b.extra ->> 'buffers_hit')::bigint + (b.extra ->> 'buffers_read')::bigint AS buffers_base,
       (p.extra ->> 'buffers_hit')::bigint + (p.extra ->> 'buffers_read')::bigint AS buffers_final,
       (b.extra ->> 'buffers_read')::bigint            AS lecturas_disco_base,
       (p.extra ->> 'buffers_read')::bigint            AS lecturas_disco_final,
       CASE WHEN p.valor < b.valor * 0.9 THEN 'MEJORA'
            WHEN p.valor > b.valor * 1.1 THEN 'EMPEORA'
            ELSE 'SIN CAMBIO' END                      AS resultado
FROM perf.consulta c
JOIN perf.medicion b ON b.concepto = c.id AND b.etapa = 'base'
JOIN perf.medicion i ON i.concepto = c.id AND i.etapa = 'indices'
JOIN perf.medicion p ON p.concepto = c.id AND p.etapa = 'parametros';

\echo '== 1. CONSULTAS: base -> índices -> índices + parámetros (ms, mejor de 3) =='
SELECT consulta, nombre, ms_base, ms_indices, ms_final, veces_mejor AS "veces", resultado FROM perf.v_comparativo ORDER BY 1;

\echo '== 2. COSTO DEL PLAN E I/O LÓGICO ======================================='
SELECT consulta, costo_base, costo_final, buffers_base, buffers_final, lecturas_disco_base, lecturas_disco_final
FROM perf.v_comparativo ORDER BY 1;

\echo '== 3. PARÁMETROS ========================================================'
SELECT p.nombre, p.valor AS antes, current_setting(p.nombre) AS despues FROM perf.parametro p WHERE etapa = 'antes' ORDER BY 1;
SELECT name AS parametro_fijo, setting || COALESCE(' ' || unit, '') AS valor, context
FROM pg_settings WHERE name = 'block_size';

\echo '== 4. CARGA MASIVA (50,000 filas) =========================================='
SELECT concepto AS metodo, valor AS ms, round(50000 / (valor / 1000)) AS filas_por_seg,
       round(valor / min(valor) OVER (), 1) AS veces_vs_mejor
FROM perf.medicion WHERE etapa = 'carga' AND concepto ~ '_50k$' ORDER BY medicion_id;
SELECT 'Carga definitiva de 500,000 empleados' AS concepto, valor AS ms FROM perf.medicion WHERE concepto = 'D_carga_definitiva_500k';

\echo '== 5. TIPOS DE ÍNDICE PARA Q2 ==========================================='
SELECT variante, construccion_ms, tamano_mb, q2_ms, nodo FROM perf.variante_indice ORDER BY variante;

\echo '== 6. ÍNDICES DEFINITIVOS Y SU USO ======================================'
SELECT regexp_replace(indexrelname, '_(empleado_(hasta|20|default)|asistencia_p[0-9]).*$', '') AS indice, sum(idx_scan) AS usos,
       pg_size_pretty(sum(pg_relation_size(indexrelid))) AS tamano
FROM pg_stat_user_indexes WHERE schemaname = 'rh' AND indexrelname ~ '^idx_(emp|asis)_'
GROUP BY 1 ORDER BY 1;

\echo '== 7. ALMACENAMIENTO ===================================================='
SELECT tablespace, tamano_mb, cuota_mb, uso_pct, objetos, estado FROM mant.v_tablespace ORDER BY 1;
SELECT tarea, count(*) AS veces FROM mant.log GROUP BY 1 ORDER BY 2 DESC, 1;
SELECT nivel, tablespace, uso_pct, accion FROM mant.alerta ORDER BY alerta_id;

\echo '== 8. SEGURIDAD: RESUMEN ================================================'
SELECT r.rolname AS usuario, COALESCE(string_agg(g.rolname, ', '), '-') AS rol, COALESCE(n.nivel::text, '-') AS nivel_mac
FROM pg_roles r
LEFT JOIN pg_auth_members m ON m.member = r.oid
LEFT JOIN pg_roles g ON g.oid = m.roleid
LEFT JOIN seg.nivel_acceso n ON n.sujeto = r.rolname
WHERE r.rolcanlogin AND r.rolname ~ '^(admin_|auditor_|analista_|usuario_)'
GROUP BY r.rolname, n.nivel ORDER BY 1;
SELECT tablename, policyname, cmd FROM pg_policies WHERE schemaname = 'rh' ORDER BY 1, 2;

\echo '== 9. VERIFICACIÓN A/B (mismas condiciones, 6 repeticiones alternadas) ====='
-- Las mediciones de la sección 1 se tomaron en momentos distintos y el equipo comparte CPU con otros
-- contenedores. Para no depender del ruido se compara, AHORA y alternando, el plan con índices contra
-- el mismo plan con los índices desactivados para el planificador (enable_*scan = off, solo en esta transacción).
CREATE TEMP TABLE ab (consulta TEXT, modo TEXT, ms NUMERIC);
DO $$
DECLARE
    q RECORD; j JSONB;
BEGIN
    FOR q IN SELECT id, sql FROM perf.consulta WHERE id IN ('Q1','Q2','Q3') ORDER BY id LOOP
        EXECUTE 'EXPLAIN (ANALYZE, FORMAT JSON) ' || q.sql INTO j;                    -- calentamiento
        FOR i IN 1..6 LOOP
            PERFORM set_config('enable_indexscan', 'on', true);  PERFORM set_config('enable_indexonlyscan', 'on', true);  PERFORM set_config('enable_bitmapscan', 'on', true);
            EXECUTE 'EXPLAIN (ANALYZE, FORMAT JSON) ' || q.sql INTO j;
            INSERT INTO ab VALUES (q.id, 'con índices', (j -> 0 ->> 'Execution Time')::numeric);
            PERFORM set_config('enable_indexscan', 'off', true); PERFORM set_config('enable_indexonlyscan', 'off', true); PERFORM set_config('enable_bitmapscan', 'off', true);
            EXECUTE 'EXPLAIN (ANALYZE, FORMAT JSON) ' || q.sql INTO j;
            INSERT INTO ab VALUES (q.id, 'sin índices', (j -> 0 ->> 'Execution Time')::numeric);
        END LOOP;
    END LOOP;
END $$;
SELECT consulta, modo, round(min(ms), 1) AS ms_min, round(avg(ms), 1) AS ms_prom, round(max(ms), 1) AS ms_max
FROM ab GROUP BY 1, 2 ORDER BY 1, 2;
