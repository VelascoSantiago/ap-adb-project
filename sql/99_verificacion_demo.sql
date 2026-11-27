-- ============================================================================
-- 99_verificacion_demo.sql  ·  Lista de verificación ANTES de la demo
-- Cada fila debe decir OK. Si alguna dice FALLA, la columna "remedio" dice qué ejecutar.
-- Uso: make check
-- ============================================================================
\echo '== VERIFICACIÓN PREVIA A LA DEMO =========================================='
SELECT n AS "#", verificacion, CASE WHEN ok THEN 'OK' ELSE 'FALLA' END AS estado, CASE WHEN ok THEN '' ELSE remedio END AS remedio
FROM (VALUES
 (1, 'Empleados cargados (>= 500,000)', (SELECT count(*) >= 500000 FROM rh.empleado), 'make bloque3'),
 (2, 'Asistencias cargadas (>= 1,000,000)', (SELECT count(*) >= 1000000 FROM rh.asistencia), 'make bloque3'),
 (3, 'Índices definitivos válidos (3)', (SELECT count(*) = 3 FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid WHERE c.relname IN ('idx_emp_ingreso_salario','idx_emp_depto_salario','idx_asis_fecha_empleado') AND i.indisvalid), 'make run F=sql/04c_advisor_indices.sql'),
 (4, 'shared_buffers = 512MB (parámetros aplicados)', (SELECT current_setting('shared_buffers') = '512MB'), 'make run F=sql/04d_parametros.sql && make restart'),
 (5, 'Mediciones completas (3 etapas x 5 consultas)', (SELECT count(*) = 15 FROM perf.medicion WHERE concepto ~ '^Q[0-9]+$'), 'make bloque3'),
 (6, 'Usuarios de la demo existen (5)', (SELECT count(*) = 5 FROM pg_roles WHERE rolname IN ('admin_santiago','auditor_armando','analista_laura','analista_jr','usuario_sin_rol')), 'make run F=sql/03_seguridad.sql'),
 (7, 'RLS activo en rh.empleado con 2 políticas', (SELECT relrowsecurity FROM pg_class WHERE oid = 'rh.empleado'::regclass) AND (SELECT count(*) = 2 FROM pg_policies WHERE tablename = 'empleado'), 'make run F=sql/03_seguridad.sql'),
 (8, 'pgaudit configurado en la BD', (SELECT count(*) > 0 FROM pg_db_role_setting s WHERE s.setdatabase = (SELECT oid FROM pg_database WHERE datname = current_database()) AND s.setconfig::text LIKE '%pgaudit.log%'), 'make run F=sql/03_seguridad.sql'),
 (9, 'Jobs de pg_cron instalados (8)', (SELECT count(*) = 8 FROM cron.job WHERE jobname LIKE 'bda\_%'), 'make run F=sql/05_almacenamiento.sql'),
 (10, 'Esquema mant instalado y tablespaces en OK', (SELECT count(*) = 4 AND bool_and(estado = 'OK') FROM mant.v_tablespace), 'make run F=sql/05_almacenamiento.sql'),
 (11, 'Bitácora sin particiones sintéticas de la demo', (SELECT count(*) = 0 FROM pg_class c JOIN pg_inherits i ON i.inhrelid = c.oid WHERE i.inhparent = 'audit.bitacora'::regclass AND c.relname ~ '_2026_(0|10)|_2027_02'), 'make run F=sql/05_almacenamiento.sql'),
 (12, 'Extensiones pgaudit, pg_cron, hypopg y pg_stat_statements', (SELECT count(*) = 4 FROM pg_extension WHERE extname IN ('pgaudit','pg_cron','hypopg','pg_stat_statements')), 'make reset && make up')
) AS t(n, verificacion, ok, remedio) ORDER BY n;
