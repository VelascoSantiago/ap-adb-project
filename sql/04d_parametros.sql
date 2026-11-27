-- ============================================================================
-- 04d_parametros.sql  ·  BLOQUE 3 (4/5): Ajuste de parámetros de memoria
-- Proyecto BDA - Equipo 7 · PostgreSQL 16 (Docker)
--
-- Equivalencia Oracle -> PostgreSQL:
--   DB_BLOCK_SIZE              -> block_size: se fija al COMPILAR PostgreSQL (8 kB), solo lectura.
--                                 No se puede cambiar con un comando; se documenta y se ajustan
--                                 los parámetros que sí influyen en cómo se usa ese bloque.
--   DB_CACHE_SIZE / SGA        -> shared_buffers (REQUIERE reinicio)
--   PGA_AGGREGATE_TARGET       -> work_mem (por operación de sort/hash) y maintenance_work_mem
--   (optimizador)              -> effective_cache_size, random_page_cost
--
-- ALTER SYSTEM escribe en postgresql.auto.conf (persistente en el volumen pgdata).
-- Después de este script: make restart  y luego 04e_comparativo.sql
-- ============================================================================

\set ON_ERROR_STOP on

CREATE TABLE IF NOT EXISTS perf.parametro (
    etapa TEXT NOT NULL, nombre TEXT NOT NULL, valor TEXT NOT NULL, PRIMARY KEY (etapa, nombre));

\echo '== 1. block_size: solo lectura ========================================='
SELECT name, setting AS bytes, context, short_desc FROM pg_settings WHERE name = 'block_size';
\echo '-- Intento de cambiarlo (debe fallar: parámetro interno, fijado al compilar):'
\set ON_ERROR_STOP off
ALTER SYSTEM SET block_size = 16384;
\set ON_ERROR_STOP on
\echo '-- Alternativa solo si se quisiera otro tamaño: compilar con ./configure --with-blocksize=16 (fuera del alcance).'

\echo '== 2. VALORES ANTES ====================================================='
-- Valores de fábrica (boot_val), convertidos a texto legible. Así es re-ejecutable.
DELETE FROM perf.parametro WHERE etapa = 'antes';
INSERT INTO perf.parametro
SELECT 'antes', name,
       CASE WHEN unit IS NULL THEN boot_val
            ELSE pg_size_pretty(boot_val::bigint * CASE unit WHEN '8kB' THEN 8192 WHEN 'kB' THEN 1024 END) END
FROM pg_settings
WHERE name IN ('shared_buffers','work_mem','maintenance_work_mem','effective_cache_size','random_page_cost');
SELECT nombre, valor FROM perf.parametro WHERE etapa = 'antes' ORDER BY nombre;

\echo '== 3. AJUSTES ==========================================================='
-- Criterio (el contenedor comparte un equipo de 8 CPU / 8 GB con otros servicios):
--   shared_buffers       128MB -> 512MB : el "working set" (~300 MB de tablas+índices) cabe en caché
--                                         (regla general: 25 % de la RAM disponible).
--   work_mem             4MB   -> 32MB  : evita ordenar/agregar en disco (SORT_A_DISCO del advisor).
--                                         Es POR operación, no por conexión: no se sube más sin medir.
--   maintenance_work_mem 64MB  -> 256MB : acelera CREATE INDEX, VACUUM, REINDEX.
--   effective_cache_size 4GB   -> 2GB   : dato para el planificador (no reserva memoria); se ajusta
--                                         a lo que realmente tiene el contenedor para cachear.
--   random_page_cost     4     -> 1.1   : almacenamiento SSD; hace más baratos los índices.
ALTER SYSTEM SET shared_buffers       = '512MB';
ALTER SYSTEM SET work_mem             = '32MB';
ALTER SYSTEM SET maintenance_work_mem = '256MB';
ALTER SYSTEM SET effective_cache_size = '2GB';
ALTER SYSTEM SET random_page_cost     = 1.1;
SELECT pg_reload_conf();
SELECT pg_sleep(1);   -- el reload es asíncrono: se espera a que el servidor lo procese

\echo '== 4. ESTADO TRAS EL RELOAD ============================================='
\echo '-- Los parámetros con context=postmaster (shared_buffers) quedan "pendientes de reinicio":'
SELECT name, setting, unit, context, pending_restart FROM pg_settings
WHERE name IN ('shared_buffers','work_mem','maintenance_work_mem','effective_cache_size','random_page_cost')
ORDER BY name;
\echo 'SIGUIENTE PASO: make restart && make run F=sql/04e_comparativo.sql'
