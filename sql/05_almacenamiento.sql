-- ============================================================================
-- 05_almacenamiento.sql  ·  BLOQUE 4: Almacenamiento y mantenimiento
-- Proyecto BDA - Equipo 7 · PostgreSQL 16 (Docker)
--
-- Contenido:
--   1. Esquema mant: cuotas, alertas y bitácora de mantenimiento
--   2. Monitoreo de tablespaces y "datafiles" (archivos de las relaciones)
--   3. Alerta y AUTOEXTENSIÓN lógica (PostgreSQL no tiene AUTOEXTEND)
--   4. Particiones dinámicas: crear, mover de tablespace, archivar (DETACH) y reincorporar (ATTACH)
--   5. Rotación y purga (TRUNCATE) de la bitácora
--   6. Escenario completo con datos sintéticos
--   7. Mantenimiento programado con pg_cron (VACUUM, REINDEX, rotación, vigilancia)
--
-- Equivalencias Oracle -> PostgreSQL:
--   DBA_DATA_FILES / DBA_FREE_SPACE      -> pg_tablespace_size(), pg_relation_filepath(), df
--   AUTOEXTEND ON NEXT .. MAXSIZE ..     -> mant.cuota_tablespace (cuota/incremento/máximo) + función
--   ALTER TABLE .. MOVE TABLESPACE       -> ALTER TABLE .. SET TABLESPACE
--   EXCHANGE / DROP PARTITION            -> DETACH PARTITION / ATTACH PARTITION
--   DBMS_SCHEDULER                       -> pg_cron
--
-- Re-ejecutable sin rehacer 02: al inicio se borran las particiones y objetos de demostración.
-- Requiere 02 (y funciona igual con los datos masivos del bloque 3).
-- ============================================================================

\set ON_ERROR_STOP on

\echo '== 0. LIMPIEZA DE LA DEMO (re-ejecutable) ==============================='
-- Se quitan los jobs de pg_cron de este bloque, el esquema de archivo y las particiones sintéticas.
SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname LIKE 'bda\_%';
DROP SCHEMA IF EXISTS archivo CASCADE;
DROP SCHEMA IF EXISTS mant    CASCADE;
DO $$
DECLARE p RECORD;
BEGIN
    FOR p IN SELECT c.oid::regclass AS tabla FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
             WHERE i.inhparent = 'audit.bitacora'::regclass
               AND c.relname NOT IN ('bitacora_2026_11','bitacora_2026_12','bitacora_2027_01','bitacora_default')
    LOOP EXECUTE format('DROP TABLE %s', p.tabla); END LOOP;
    IF to_regclass('rh.empleado_2028_2031') IS NOT NULL THEN DROP TABLE rh.empleado_2028_2031; END IF;
END $$;
-- La demo borra filas sintéticas que cayeron en la partición por defecto
DELETE FROM audit.bitacora_default WHERE usuario = 'demo_sintetico';

\echo '== 1. ESQUEMA mant ======================================================'
CREATE SCHEMA mant;
CREATE SCHEMA archivo;
COMMENT ON SCHEMA mant    IS 'Monitoreo de espacio, particiones dinámicas y mantenimiento';
COMMENT ON SCHEMA archivo IS 'Particiones desprendidas (DETACH) de la bitácora, en almacenamiento frío';

-- "Datafile lógico" de cada tablespace. Los volúmenes Docker comparten el disco del host, así que
-- el límite real no existe: se modela la cuota como en Oracle (tamaño actual / NEXT / MAXSIZE).
CREATE TABLE mant.cuota_tablespace (
    spcname         NAME PRIMARY KEY,
    cuota_mb        NUMERIC NOT NULL CHECK (cuota_mb > 0),      -- tamaño actual del "datafile"
    incremento_mb   NUMERIC NOT NULL CHECK (incremento_mb > 0), -- NEXT
    max_mb          NUMERIC NOT NULL,                           -- MAXSIZE
    umbral_aviso    NUMERIC NOT NULL DEFAULT 70,                -- % para ADVERTENCIA
    umbral_critico  NUMERIC NOT NULL DEFAULT 85,                -- % para CRITICO / autoextender
    CHECK (max_mb >= cuota_mb)
);
INSERT INTO mant.cuota_tablespace (spcname, cuota_mb, incremento_mb, max_mb) VALUES
    ('ts_hot',  200, 100, 600),
    ('ts_warm', 200, 100, 600),
    ('ts_cold', 300, 100, 900),
    ('ts_idx',  400, 100, 1200);

CREATE TABLE mant.alerta (
    alerta_id  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    fecha      TIMESTAMPTZ NOT NULL DEFAULT now(),
    nivel      TEXT NOT NULL,           -- ADVERTENCIA | CRITICO
    tablespace NAME NOT NULL,
    uso_pct    NUMERIC NOT NULL,
    accion     TEXT NOT NULL
);

CREATE TABLE mant.log (
    log_id  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    fecha   TIMESTAMPTZ NOT NULL DEFAULT now(),
    tarea   TEXT NOT NULL,
    objeto  TEXT,
    detalle TEXT
);

\echo '== 2. MONITOREO ========================================================='

-- 2.1 Estado de cada tablespace frente a su cuota (equivale a DBA_TABLESPACE_USAGE_METRICS)
CREATE VIEW mant.v_tablespace AS
SELECT t.spcname                                              AS tablespace,
       pg_tablespace_location(t.oid)                          AS ubicacion,
       round(pg_tablespace_size(t.oid) / 1048576.0, 1)        AS tamano_mb,
       q.cuota_mb, q.max_mb,
       round(100 * pg_tablespace_size(t.oid) / 1048576.0 / q.cuota_mb, 1) AS uso_pct,
       (SELECT count(*) FROM pg_class c WHERE c.reltablespace = t.oid)    AS objetos,
       CASE WHEN 100 * pg_tablespace_size(t.oid) / 1048576.0 / q.cuota_mb >= q.umbral_critico THEN 'CRITICO'
            WHEN 100 * pg_tablespace_size(t.oid) / 1048576.0 / q.cuota_mb >= q.umbral_aviso   THEN 'ADVERTENCIA'
            ELSE 'OK' END                                     AS estado
FROM pg_tablespace t JOIN mant.cuota_tablespace q ON q.spcname = t.spcname;

-- 2.2 "Datafiles": cada tabla/índice es un archivo en el directorio del tablespace.
--     pg_relation_filepath() da la ruta (equivale a DBA_DATA_FILES.FILE_NAME).
CREATE VIEW mant.v_archivo_datos AS
SELECT n.nspname || '.' || c.relname                      AS objeto,
       CASE c.relkind WHEN 'r' THEN 'tabla' WHEN 'i' THEN 'índice' WHEN 'm' THEN 'vista mat.' END AS tipo,
       COALESCE(t.spcname, 'pg_default')                  AS tablespace,
       pg_relation_filepath(c.oid)                        AS archivo,
       pg_relation_size(c.oid)                            AS bytes,
       pg_size_pretty(pg_relation_size(c.oid))            AS tamano
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
LEFT JOIN pg_tablespace t ON t.oid = c.reltablespace
WHERE c.relkind IN ('r','i','m') AND n.nspname IN ('rh','audit','archivo');

-- 2.3 Espacio REAL del sistema de archivos (df dentro del contenedor). Usa COPY ... FROM PROGRAM,
--     que exige superusuario: por eso la función es SECURITY DEFINER y pertenece a postgres.
CREATE FUNCTION mant.fn_df()
RETURNS TABLE (tablespace NAME, sistema_archivos TEXT, total_mb NUMERIC, usado_mb NUMERIC, libre_mb NUMERIC, uso_pct NUMERIC)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = mant, pg_catalog, pg_temp
AS $$
DECLARE
    t RECORD;
    linea TEXT;
    c TEXT[];
BEGIN
    CREATE TEMP TABLE IF NOT EXISTS tmp_df (linea TEXT) ON COMMIT DROP;
    FOR t IN SELECT spcname, pg_tablespace_location(oid) AS loc FROM pg_tablespace WHERE spcname LIKE 'ts\_%' ORDER BY 1 LOOP
        TRUNCATE tmp_df;
        EXECUTE format('COPY tmp_df FROM PROGRAM %L', 'df -Pk ' || t.loc || ' | tail -n 1');
        SELECT d.linea INTO linea FROM tmp_df d LIMIT 1;
        c := string_to_array(regexp_replace(linea, '\s+', ' ', 'g'), ' ');
        tablespace := t.spcname; sistema_archivos := c[1];
        total_mb := round(c[2]::numeric / 1024, 0); usado_mb := round(c[3]::numeric / 1024, 0);
        libre_mb := round(c[4]::numeric / 1024, 0); uso_pct := trim(trailing '%' FROM c[5])::numeric;
        RETURN NEXT;
    END LOOP;
END $$;

\echo '-- 2.4 Tablespaces frente a su cuota'
SELECT tablespace, tamano_mb, cuota_mb, max_mb, uso_pct, objetos, estado FROM mant.v_tablespace ORDER BY 1;

\echo '-- 2.5 Ubicación física y sistema de archivos (los 4 volúmenes comparten el disco del host)'
SELECT tablespace, ubicacion FROM mant.v_tablespace ORDER BY 1;
SELECT * FROM mant.fn_df();

\echo '-- 2.6 Los 10 archivos más grandes ("datafiles") y a qué tablespace pertenecen'
SELECT objeto, tipo, tablespace, archivo, tamano FROM mant.v_archivo_datos ORDER BY bytes DESC LIMIT 10;

\echo '-- 2.7 Tamaño por tablespace y por tipo de objeto'
SELECT tablespace, tipo, count(*) AS archivos, pg_size_pretty(sum(bytes)) AS tamano
FROM mant.v_archivo_datos GROUP BY 1, 2 ORDER BY 1, 2;

\echo '== 3. ALERTA Y AUTOEXTENSIÓN LÓGICA ======================================'
-- Reglas (equivalentes a AUTOEXTEND ON NEXT <incremento> MAXSIZE <max>):
--   uso >= umbral_aviso                  -> ADVERTENCIA (se registra en mant.alerta)
--   uso >= umbral_critico, hay margen    -> la cuota crece en 'incremento_mb' (hasta max_mb)
--   uso >= umbral_critico, sin margen    -> CRITICO: hay que mover/archivar/purgar particiones
-- Se ejecuta periódicamente con pg_cron (sección 7).
CREATE FUNCTION mant.fn_verificar_espacio(p_autoextender BOOLEAN DEFAULT TRUE)
RETURNS TABLE (tablespace NAME, tamano_mb NUMERIC, cuota_mb NUMERIC, uso_pct NUMERIC, nivel TEXT, accion TEXT)
LANGUAGE plpgsql AS $$
DECLARE
    q   mant.cuota_tablespace%ROWTYPE;
    v_mb NUMERIC;
BEGIN
    FOR q IN SELECT * FROM mant.cuota_tablespace ORDER BY spcname LOOP
        v_mb := round(pg_tablespace_size(q.spcname) / 1048576.0, 1);
        tablespace := q.spcname; tamano_mb := v_mb; cuota_mb := q.cuota_mb;
        uso_pct := round(100 * v_mb / q.cuota_mb, 1);

        IF uso_pct >= q.umbral_critico THEN
            nivel := 'CRITICO';
            IF p_autoextender AND q.cuota_mb + q.incremento_mb <= q.max_mb THEN
                UPDATE mant.cuota_tablespace c SET cuota_mb = c.cuota_mb + c.incremento_mb WHERE c.spcname = q.spcname;
                accion := format('AUTOEXTEND: cuota %s -> %s MB', q.cuota_mb, q.cuota_mb + q.incremento_mb);
                INSERT INTO mant.log (tarea, objeto, detalle) VALUES ('autoextend', q.spcname, accion);
            ELSE
                accion := 'SIN MARGEN: archivar, mover o purgar particiones';
            END IF;
        ELSIF uso_pct >= q.umbral_aviso THEN
            nivel := 'ADVERTENCIA'; accion := 'Planificar crecimiento';
        ELSE
            nivel := 'OK'; accion := '-';
        END IF;

        IF nivel <> 'OK' THEN
            INSERT INTO mant.alerta (nivel, tablespace, uso_pct, accion) VALUES (nivel, q.spcname, uso_pct, accion);
        END IF;
        RETURN NEXT;
    END LOOP;
END $$;

\echo '-- 3.1 Estado actual (todo debe estar OK)'
SELECT * FROM mant.fn_verificar_espacio();

\echo '== 4. PARTICIONES DINÁMICAS ============================================='

-- 4.1 Crea una partición de rango y deja los índices en ts_idx. Si la partición por defecto ya
--     contiene filas de ese rango (caso real: llegaron datos antes de crear la partición),
--     PostgreSQL rechazaría el CREATE ... PARTITION OF; entonces se crea una tabla suelta, se
--     MUEVEN las filas desde la default y se hace ATTACH. Es idempotente.
CREATE FUNCTION mant.fn_crear_particion_rango(p_padre REGCLASS, p_nombre TEXT, p_desde TEXT, p_hasta TEXT, p_ts NAME)
RETURNS TEXT
LANGUAGE plpgsql AS $$
DECLARE
    v_esq     TEXT := (SELECT n.nspname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.oid = p_padre);
    v_col     TEXT := substring(pg_get_partkeydef(p_padre) FROM '\((.*)\)');
    v_def     REGCLASS;
    v_filas   BIGINT := 0;
    v_nueva   TEXT := format('%I.%I', v_esq, p_nombre);
    v_movidas BIGINT := 0;
    i         RECORD;
BEGIN
    IF to_regclass(v_nueva) IS NOT NULL THEN RETURN v_nueva || ': ya existe'; END IF;

    SELECT pt.relid INTO v_def FROM pg_partition_tree(p_padre) pt JOIN pg_class c ON c.oid = pt.relid
    WHERE pt.isleaf AND pg_get_expr(c.relpartbound, c.oid) = 'DEFAULT';
    IF v_def IS NOT NULL THEN
        EXECUTE format('SELECT count(*) FROM %s WHERE %I >= %L AND %I < %L', v_def, v_col, p_desde, v_col, p_hasta) INTO v_filas;
    END IF;

    IF v_filas = 0 THEN
        EXECUTE format('CREATE TABLE %s PARTITION OF %s FOR VALUES FROM (%L) TO (%L) TABLESPACE %I',
                       v_nueva, p_padre, p_desde, p_hasta, p_ts);
    ELSE
        EXECUTE format('CREATE TABLE %s (LIKE %s INCLUDING DEFAULTS INCLUDING CONSTRAINTS) TABLESPACE %I', v_nueva, p_padre, p_ts);
        EXECUTE format('WITH d AS (DELETE FROM %s WHERE %I >= %L AND %I < %L RETURNING *) INSERT INTO %s SELECT * FROM d',
                       v_def, v_col, p_desde, v_col, p_hasta, v_nueva);
        v_movidas := v_filas;
        EXECUTE format('ALTER TABLE %s ATTACH PARTITION %s FOR VALUES FROM (%L) TO (%L)', p_padre, v_nueva, p_desde, p_hasta);
    END IF;

    -- Los índices de la partición nueva se dejan en ts_idx (convención del proyecto)
    FOR i IN SELECT indexrelid::regclass AS idx FROM pg_index WHERE indrelid = v_nueva::regclass LOOP
        EXECUTE format('ALTER INDEX %s SET TABLESPACE ts_idx', i.idx);
    END LOOP;

    INSERT INTO mant.log (tarea, objeto, detalle)
    VALUES ('crear_particion', v_nueva, format('[%s, %s) en %s; %s fila(s) movidas desde la default', p_desde, p_hasta, p_ts, v_movidas));
    RETURN format('%s: creada en %s (%s fila(s) movidas desde la default)', v_nueva, p_ts, v_movidas);
END $$;

-- 4.2 Mantiene siempre las particiones mensuales de la bitácora de los próximos N meses.
CREATE FUNCTION mant.fn_preparar_particiones(p_meses_adelante INT DEFAULT 3)
RETURNS TABLE (resultado TEXT)
LANGUAGE plpgsql AS $$
DECLARE
    v_mes DATE;
BEGIN
    FOR i IN 0..p_meses_adelante LOOP
        v_mes := (date_trunc('month', now()) + make_interval(months => i))::date;
        resultado := mant.fn_crear_particion_rango('audit.bitacora', 'bitacora_' || to_char(v_mes, 'YYYY_MM'),
                         v_mes::text, (v_mes + INTERVAL '1 month')::date::text, 'ts_hot');
        RETURN NEXT;
    END LOOP;
END $$;

-- 4.3 Mueve una partición a otro tablespace (ALTER TABLE ... SET TABLESPACE reescribe el archivo
--     y bloquea la tabla en ACCESS EXCLUSIVE mientras dura: hacerlo en ventana de mantenimiento).
CREATE FUNCTION mant.fn_mover_particion(p_part REGCLASS, p_ts NAME)
RETURNS TEXT
LANGUAGE plpgsql AS $$
DECLARE
    v_antes TEXT := pg_relation_filepath(p_part);
BEGIN
    EXECUTE format('ALTER TABLE %s SET TABLESPACE %I', p_part, p_ts);
    INSERT INTO mant.log (tarea, objeto, detalle) VALUES ('mover_particion', p_part::text, 'a ' || p_ts);
    RETURN format('%s: %s -> %s', p_part, v_antes, pg_relation_filepath(p_part));
END $$;

-- 4.4 Archiva una partición: DETACH (sale de la tabla, los datos se conservan), pasa al esquema
--     archivo y a ts_cold. Una consulta sobre la bitácora ya no la lee.
CREATE FUNCTION mant.fn_archivar_particion(p_part REGCLASS)
RETURNS TEXT
LANGUAGE plpgsql AS $$
DECLARE
    v_padre REGCLASS := (SELECT inhparent FROM pg_inherits WHERE inhrelid = p_part);
    v_nombre TEXT := (SELECT relname FROM pg_class WHERE oid = p_part);
BEGIN
    EXECUTE format('ALTER TABLE %s DETACH PARTITION %s', v_padre, p_part);
    EXECUTE format('ALTER TABLE %s SET SCHEMA archivo', p_part);
    EXECUTE format('ALTER TABLE archivo.%I SET TABLESPACE ts_cold', v_nombre);
    INSERT INTO mant.log (tarea, objeto, detalle) VALUES ('archivar', 'archivo.' || v_nombre, 'DETACH desde ' || v_padre);
    RETURN format('archivo.%s (desprendida de %s)', v_nombre, v_padre);
END $$;

\echo '== 5. ROTACIÓN Y PURGA DE LA BITÁCORA ===================================='

-- 5.1 Archiva las particiones con más de N meses de antigüedad.
CREATE FUNCTION mant.fn_rotar_bitacora(p_meses_en_linea INT DEFAULT 3)
RETURNS TABLE (resultado TEXT)
LANGUAGE plpgsql AS $$
DECLARE
    p RECORD;
BEGIN
    FOR p IN SELECT c.oid::regclass AS tabla,
                    to_date(substring(c.relname FROM '(\d{4}_\d{2})$'), 'YYYY_MM') AS mes
             FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
             WHERE i.inhparent = 'audit.bitacora'::regclass AND c.relname ~ '\d{4}_\d{2}$'
               AND to_date(substring(c.relname FROM '(\d{4}_\d{2})$'), 'YYYY_MM')
                   < (date_trunc('month', now()) - make_interval(months => p_meses_en_linea))::date
             ORDER BY 2
    LOOP
        resultado := mant.fn_archivar_particion(p.tabla);
        RETURN NEXT;
    END LOOP;
END $$;

-- 5.2 TRUNCATE + DROP de lo archivado hace más de N meses (libera el espacio de inmediato;
--     TRUNCATE no recorre fila por fila y no deja tuplas muertas, a diferencia de DELETE).
CREATE FUNCTION mant.fn_purgar_archivo(p_meses_retencion INT DEFAULT 12)
RETURNS TABLE (resultado TEXT)
LANGUAGE plpgsql AS $$
DECLARE
    p RECORD;
    v_mb NUMERIC;
BEGIN
    FOR p IN SELECT c.relname, c.oid::regclass AS tabla
             FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE n.nspname = 'archivo' AND c.relkind = 'r'
               AND to_date(substring(c.relname FROM '(\d{4}_\d{2})$'), 'YYYY_MM')
                   < (date_trunc('month', now()) - make_interval(months => p_meses_retencion))::date
             ORDER BY 1
    LOOP
        v_mb := round(pg_total_relation_size(p.tabla) / 1048576.0, 1);
        EXECUTE format('TRUNCATE %s', p.tabla);
        EXECUTE format('DROP TABLE %s', p.tabla);
        INSERT INTO mant.log (tarea, objeto, detalle) VALUES ('purgar', p.relname, format('TRUNCATE + DROP, liberó %s MB', v_mb));
        resultado := format('archivo.%s purgada (%s MB liberados)', p.relname, v_mb);
        RETURN NEXT;
    END LOOP;
END $$;

\echo '== 6. ESCENARIO COMPLETO CON DATOS SINTÉTICOS ============================'

\echo '-- 6.1 Llegan registros de bitácora de enero a octubre 2026 SIN partición propia: caen en la default'
INSERT INTO audit.bitacora (fecha, usuario, operacion, esquema, tabla, registro_id, datos_old, datos_new)
SELECT timestamptz '2026-01-01' + (m * INTERVAL '1 month') + (g * INTERVAL '2 minutes'),
       'demo_sintetico', (ARRAY['INSERT','UPDATE','DELETE'])[1 + g % 3], 'rh', 'empleado', (g + m * 100000)::text,
       jsonb_build_object('empleado_id', g, 'nombre', md5(g::text), 'email', md5(g::text) || '@empresa.mx', 'salario', 10000 + g % 5000),
       jsonb_build_object('empleado_id', g, 'nombre', md5((g + 1)::text), 'email', md5((g + 1)::text) || '@empresa.mx', 'salario', 10000 + (g + 7) % 5000)
FROM generate_series(0, 9) AS m, generate_series(1, 20000) AS g;
SELECT tableoid::regclass AS particion, count(*) AS filas FROM audit.bitacora GROUP BY 1 ORDER BY 1;

\echo '-- 6.2 Crear las particiones faltantes: las filas se MUEVEN desde la default (ene-jul a ts_cold, ago-oct a ts_hot)'
SELECT mant.fn_crear_particion_rango('audit.bitacora', 'bitacora_' || to_char(mes, 'YYYY_MM'),
           mes::text, (mes + INTERVAL '1 month')::date::text,
           CASE WHEN mes < DATE '2026-08-01' THEN 'ts_cold' ELSE 'ts_hot' END) AS resultado
FROM generate_series(DATE '2026-01-01', DATE '2026-10-01', INTERVAL '1 month') AS g(mes) ORDER BY mes;

\echo '-- 6.3 Particiones dinámicas hacia adelante (job mensual): garantiza los próximos 3 meses'
SELECT * FROM mant.fn_preparar_particiones(3);
SELECT * FROM mant.fn_preparar_particiones(3);   -- idempotente: la segunda vez todo "ya existe"

\echo '-- 6.4 Estado de la bitácora: partición, tablespace, límites y filas'
SELECT c.relname AS particion, COALESCE(t.spcname, 'pg_default') AS tablespace,
       pg_get_expr(c.relpartbound, c.oid) AS limites,
       (xpath('/row/c/text()', query_to_xml(format('SELECT count(*) AS c FROM %s', c.oid::regclass), false, true, '')))[1]::text::bigint AS filas
FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid LEFT JOIN pg_tablespace t ON t.oid = c.reltablespace
WHERE i.inhparent = 'audit.bitacora'::regclass ORDER BY c.relname;

\echo '-- 6.5 Partition pruning: una consulta de septiembre solo lee bitacora_2026_09'
EXPLAIN (COSTS OFF) SELECT count(*) FROM audit.bitacora WHERE fecha >= '2026-09-01' AND fecha < '2026-10-01';

\echo '-- 6.6 Partición nueva también en la tabla de empleados (rango 2028-2031), usando la misma función'
SELECT mant.fn_crear_particion_rango('rh.empleado', 'empleado_2028_2031', '2028-01-01', '2032-01-01', 'ts_hot');
SELECT c.relname, t.spcname AS tablespace, pg_get_expr(c.relpartbound, c.oid) AS limites
FROM pg_class c LEFT JOIN pg_tablespace t ON t.oid = c.reltablespace WHERE c.relname = 'empleado_2028_2031';

\echo '== 6.7 MOVER una partición entre tablespaces (ALTER TABLE ... SET TABLESPACE)'
SELECT objeto, tablespace, archivo, tamano FROM mant.v_archivo_datos WHERE objeto = 'audit.bitacora_2026_10';
SELECT mant.fn_mover_particion('audit.bitacora_2026_10', 'ts_warm');
SELECT objeto, tablespace, archivo, tamano FROM mant.v_archivo_datos WHERE objeto = 'audit.bitacora_2026_10';
SELECT mant.fn_mover_particion('audit.bitacora_2026_10', 'ts_hot');   -- se devuelve a ts_hot

\echo '== 6.8 AUTOEXTENSIÓN: ts_hot supera el umbral crítico y la cuota crece'
-- Se ajusta la cuota para forzar el escenario de forma reproducible: uso = 90 %.
UPDATE mant.cuota_tablespace SET cuota_mb = ceil(pg_tablespace_size(spcname) / 1048576.0 / 0.90) WHERE spcname = 'ts_hot';
SELECT tablespace, tamano_mb, cuota_mb, uso_pct, estado FROM mant.v_tablespace WHERE tablespace = 'ts_hot';
SELECT * FROM mant.fn_verificar_espacio() WHERE tablespace = 'ts_hot';
SELECT tablespace, tamano_mb, cuota_mb, uso_pct, estado FROM mant.v_tablespace WHERE tablespace = 'ts_hot';

\echo '== 6.9 SIN MARGEN: ts_cold llega al límite y se resuelve archivando + purgando'
\echo '-- (a) Se archivan las particiones con más de 3 meses: DETACH + esquema archivo + ts_cold'
SELECT * FROM mant.fn_rotar_bitacora(3);
\echo '-- (b) Las archivadas siguen existiendo como tablas, pero ya no forman parte de audit.bitacora'
SELECT n.nspname || '.' || c.relname AS tabla, pg_size_pretty(pg_total_relation_size(c.oid)) AS tamano
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'archivo' AND c.relkind = 'r' ORDER BY 1;
\echo '-- (c) ts_cold queda al 92 % de una cuota que ya no se puede ampliar (max = cuota)'
UPDATE mant.cuota_tablespace SET cuota_mb = ceil(pg_tablespace_size(spcname) / 1048576.0 / 0.92), incremento_mb = 10,
       max_mb = ceil(pg_tablespace_size(spcname) / 1048576.0 / 0.92) WHERE spcname = 'ts_cold';
SELECT * FROM mant.fn_verificar_espacio() WHERE tablespace = 'ts_cold';
\echo '-- (d) Remedio: purgar (TRUNCATE + DROP) lo archivado con más de 6 meses'
SELECT * FROM mant.fn_purgar_archivo(6);
SELECT * FROM mant.fn_verificar_espacio() WHERE tablespace = 'ts_cold';

\echo '== 6.10 REINCORPORAR una partición archivada (ATTACH PARTITION)'
-- Los datos nunca se perdieron; vuelven a ser parte de audit.bitacora sin copiar filas.
ALTER TABLE archivo.bitacora_2026_05 SET SCHEMA audit;
ALTER TABLE audit.bitacora ATTACH PARTITION audit.bitacora_2026_05
    FOR VALUES FROM ('2026-05-01') TO ('2026-06-01');
SELECT tableoid::regclass AS particion, count(*) AS filas FROM audit.bitacora WHERE fecha < '2026-07-01' GROUP BY 1 ORDER BY 1;
-- y se vuelve a archivar
SELECT mant.fn_archivar_particion('audit.bitacora_2026_05');

\echo '-- 6.11 Resumen de alertas y acciones registradas'
SELECT alerta_id, nivel, tablespace, uso_pct, accion FROM mant.alerta ORDER BY alerta_id;
SELECT tarea, objeto, detalle FROM mant.log ORDER BY log_id;

\echo '== 7. MANTENIMIENTO: VACUUM, REINDEX, TRUNCATE ==========================='
\echo '-- 7.1 Basura generada por UPDATE (tuplas muertas) en rh.asistencia'
UPDATE rh.asistencia SET hora_salida = hora_salida + INTERVAL '1 minute' WHERE empleado_id % 4 = 0;
SELECT pg_stat_force_next_flush();
SELECT pg_sleep(1);
SELECT relname, n_live_tup, n_dead_tup, pg_size_pretty(pg_total_relation_size(relid)) AS tamano
FROM pg_stat_user_tables WHERE relname ~ '^asistencia_p[0-9]$' ORDER BY 1;

\echo '-- 7.2 VACUUM (ANALYZE): marca el espacio como reutilizable y actualiza estadísticas'
VACUUM (ANALYZE) rh.asistencia;
SELECT pg_sleep(1);
SELECT relname, n_live_tup, n_dead_tup, pg_size_pretty(pg_total_relation_size(relid)) AS tamano
FROM pg_stat_user_tables WHERE relname ~ '^asistencia_p[0-9]$' ORDER BY 1;

\echo '-- 7.3 VACUUM FULL reconstruye la tabla y DEVUELVE espacio al sistema operativo (bloquea la tabla)'
SELECT pg_size_pretty(pg_total_relation_size('rh.asistencia_p0')) AS antes;
VACUUM (FULL, ANALYZE) rh.asistencia_p0;
SELECT pg_size_pretty(pg_total_relation_size('rh.asistencia_p0')) AS despues;

\echo '-- 7.4 REINDEX CONCURRENTLY: reconstruye los índices de la tabla sin bloquear'
\timing on
REINDEX TABLE CONCURRENTLY rh.asistencia;
\timing off

\echo '-- 7.5 Los índices siguen válidos y en ts_idx'
SELECT count(*) FILTER (WHERE i.indisvalid) AS validos, count(*) AS total,
       string_agg(DISTINCT COALESCE(t.spcname, 'pg_default'), ',') AS tablespaces
FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid LEFT JOIN pg_tablespace t ON t.oid = c.reltablespace
WHERE i.indrelid IN (SELECT relid FROM pg_partition_tree('rh.asistencia'));

\echo '== 8. PROGRAMACIÓN CON pg_cron =========================================='
-- Cada tarea es un job independiente (VACUUM y REINDEX CONCURRENTLY no pueden ir dentro de
-- una transacción, así que no se agrupan varios comandos en un mismo job).
SELECT cron.schedule('bda_vigilancia_espacio',   '*/5 * * * *', $$SELECT * FROM mant.fn_verificar_espacio()$$);
SELECT cron.schedule('bda_particiones_futuras',  '0 3 25 * *',  $$SELECT * FROM mant.fn_preparar_particiones(3)$$);
SELECT cron.schedule('bda_rotacion_bitacora',    '0 4 1 * *',   $$SELECT * FROM mant.fn_rotar_bitacora(3)$$);
SELECT cron.schedule('bda_purga_archivo',        '30 4 1 * *',  $$SELECT * FROM mant.fn_purgar_archivo(12)$$);
SELECT cron.schedule('bda_vacuum_empleado',      '0 2 * * 0',   $$VACUUM (ANALYZE) rh.empleado$$);
SELECT cron.schedule('bda_vacuum_asistencia',    '15 2 * * 0',  $$VACUUM (ANALYZE) rh.asistencia$$);
SELECT cron.schedule('bda_reindex_asistencia',   '0 3 * * 0',   $$REINDEX TABLE CONCURRENTLY rh.asistencia$$);
SELECT cron.schedule('bda_limpia_historial_cron','0 5 * * *',   $$DELETE FROM cron.job_run_details WHERE end_time < now() - interval '7 days'$$);

\echo '-- 8.1 Jobs programados'
SELECT jobname, schedule, command, active FROM cron.job WHERE jobname LIKE 'bda\_%' ORDER BY jobname;

\echo '-- 8.2 Demostración sin esperar al domingo: jobs cada pocos segundos (pg_cron admite intervalos en segundos)'
SELECT cron.schedule('bda_demo_vigilancia', '4 seconds', $$SELECT * FROM mant.fn_verificar_espacio()$$);
SELECT cron.schedule('bda_demo_vacuum',     '5 seconds', $$VACUUM (ANALYZE) rh.departamento$$);
SELECT pg_sleep(14);

SELECT j.jobname, d.status, left(d.return_message, 40) AS resultado, to_char(d.start_time, 'HH24:MI:SS') AS inicio
FROM cron.job_run_details d JOIN cron.job j USING (jobid)
WHERE j.jobname LIKE 'bda\_demo%' ORDER BY d.start_time;

SELECT cron.unschedule('bda_demo_vigilancia');
SELECT cron.unschedule('bda_demo_vacuum');

\echo '-- 8.3 Jobs que quedan programados (los de demo se dieron de baja)'
SELECT jobname, schedule FROM cron.job WHERE jobname LIKE 'bda\_%' ORDER BY jobname;

\echo '== 9. RESTAURAR EL ESTADO (la demo deja datos sintéticos) ================'
-- Se quitan las particiones y datos de demostración para no ensuciar las demás demos,
-- y las cuotas vuelven a su valor inicial. Las funciones, vistas y jobs de mant quedan instalados.
DO $$
DECLARE p RECORD;
BEGIN
    FOR p IN SELECT c.oid::regclass AS tabla FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
             WHERE i.inhparent = 'audit.bitacora'::regclass
               AND c.relname NOT IN ('bitacora_2026_11','bitacora_2026_12','bitacora_2027_01','bitacora_default')
    LOOP EXECUTE format('DROP TABLE %s', p.tabla); END LOOP;
    DROP TABLE rh.empleado_2028_2031;
END $$;
DROP SCHEMA archivo CASCADE;
CREATE SCHEMA archivo;
UPDATE mant.cuota_tablespace SET cuota_mb = CASE spcname WHEN 'ts_cold' THEN 300 WHEN 'ts_idx' THEN 400 ELSE 200 END,
                                 incremento_mb = 100,
                                 max_mb = CASE spcname WHEN 'ts_cold' THEN 900 WHEN 'ts_idx' THEN 1200 ELSE 600 END;
SELECT tablespace, tamano_mb, cuota_mb, uso_pct, estado FROM mant.v_tablespace ORDER BY 1;
