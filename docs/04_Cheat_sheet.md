# Cheat sheet para la demo (Equipo 7)

Para cuando el profesor pida algo que no está en el guion. Todo corre dentro del contenedor `bda-postgres`, BD `empleados`.
Guion completo: `docs/03_Guion_demo.md`.

## 0. Arrancar y comprobar

```bash
systemctl --user start docker-desktop        # esperar a que esté listo
make up && make check                        # 12 filas en OK
make psql                                    # consola como postgres
make audit-log                               # guarda el log de pgaudit en evidencias/
make reset                                   # BORRA todo (solo si hay que empezar de cero)
```

## 1. Cambiar de usuario

Desde una terminal nueva (una conexión por rol):

```bash
docker exec -it bda-postgres psql -d empleados -U postgres
docker exec -it bda-postgres psql -d empleados -U admin_santiago
docker exec -it bda-postgres psql -d empleados -U analista_laura
docker exec -it bda-postgres psql -d empleados -U analista_jr
docker exec -it bda-postgres psql -d empleados -U auditor_armando
docker exec -it bda-postgres psql -d empleados -U usuario_sin_rol
```

Sin salir de psql: `\c empleados analista_laura` (si pide contraseña, ver tabla).
Desde el superusuario, sin contraseña: `SET ROLE analista_laura;` y volver con `RESET ROLE;`.
Quién soy: `SELECT current_user, session_user, seg.fn_nivel_acceso();`

| Usuario | Contraseña | Rol de grupo | Nivel MAC | Puede |
|---|---|---|---|---|
| `admin_santiago` | `Demo#Admin26` | `rol_admin` | 3 | CRUD en `rh`, GRANT OPTION; no lee la bitácora; sin TRUNCATE |
| `analista_laura` | `Demo#Analis26` | `rol_analista` | 2 | Lectura sin `email`, niveles 1 y 2 |
| `analista_jr` | `Demo#Junior26` | `rol_analista` | 1 | Igual, solo nivel 1 |
| `auditor_armando` | `Demo#Audit26` | `rol_auditor` | 3 | Lee todo y `audit.bitacora`; no modifica |
| `usuario_sin_rol` | `Demo#Nada26` | ninguno | 0 | Se conecta; todo denegado |

## 2. Comandos de psql

| Comando | Qué hace |
|---|---|
| `\l` / `\c bd` | listar / cambiar de base |
| `\dn` | esquemas (`rh`, `audit`, `seg`, `perf`, `mant`) |
| `\dt rh.*` / `\d+ rh.empleado` | tablas / estructura, particiones, triggers |
| `\dv rh.*` / `\df audit.*` | vistas / funciones |
| `\du` / `\du+` | roles y atributos |
| `\dp rh.*` | privilegios (GRANT) de cada objeto |
| `\db+` | tablespaces |
| `\dx` | extensiones |
| `\x` | salida vertical (útil en EXPLAIN y filas anchas) |
| `\timing` | muestra el tiempo de cada consulta |
| `\q` | salir |

## 3. Si piden... (receta rápida)

### Seguridad

```sql
-- Crear un usuario y asignarle un rol
CREATE ROLE usuario_nuevo LOGIN PASSWORD 'Clave#123' IN ROLE rol_analista;
-- Quitarle o darle un rol
REVOKE rol_analista FROM usuario_nuevo;  GRANT rol_auditor TO usuario_nuevo;
-- Darle un nivel MAC propio (el nivel por usuario gana al del rol)
INSERT INTO seg.nivel_acceso (sujeto, nivel) VALUES ('usuario_nuevo', 1);
-- DAC: dar y quitar permisos (como admin_santiago)
GRANT SELECT ON rh.departamento TO usuario_sin_rol;  REVOKE SELECT ON rh.departamento FROM usuario_sin_rol;
-- Permiso por columna
GRANT SELECT (nombre, apellido) ON rh.empleado TO usuario_nuevo;
-- Ver quién tiene qué
SELECT grantee, table_schema, table_name, privilege_type FROM information_schema.role_table_grants WHERE grantee = 'rol_analista';
SELECT r.rolname AS rol, m.rolname AS miembro FROM pg_auth_members a JOIN pg_roles r ON r.oid=a.roleid JOIN pg_roles m ON m.oid=a.member;
-- Políticas de RLS (MAC)
SELECT policyname, cmd, roles, qual FROM pg_policies WHERE tablename = 'empleado';
-- Limpieza
DROP OWNED BY usuario_nuevo; DROP ROLE usuario_nuevo;
```

### Auditoría

```sql
-- Como auditor_armando o postgres: quién cambió qué
SELECT bitacora_id, usuario, operacion, registro_id, datos_old->>'salario' AS antes, datos_new->>'salario' AS despues
FROM audit.bitacora ORDER BY bitacora_id DESC LIMIT 10;
-- Prueba de trigger de validación (debe fallar) y de auditoría (debe aparecer en la bitácora)
UPDATE rh.empleado SET salario = 90000 WHERE email = 'sofia.martinez@empresa.mx';
UPDATE rh.empleado SET salario = 36500 WHERE email = 'elena.flores@empresa.mx';
```
Log de pgaudit en vivo: `docker logs -f --tail 0 bda-postgres 2>&1 | grep --line-buffered AUDIT`

### Rendimiento

```sql
EXPLAIN (ANALYZE, BUFFERS) SELECT ...;                    -- plan real, tiempo y buffers
EXPLAIN (COSTS OFF) SELECT * FROM rh.empleado WHERE fecha_ingreso >= '2025-01-01';   -- pruning
-- Índices
\di+ rh.*                                                 -- índices y tamaño
CREATE INDEX CONCURRENTLY idx_prueba ON rh.asistencia_p0 (fecha);   -- en particiones, no en el padre
DROP INDEX rh.idx_prueba;   REINDEX INDEX CONCURRENTLY rh.idx_prueba;
-- Índice hipotético (hypopg), sin crearlo
SELECT hypopg_create_index('CREATE INDEX ON rh.empleado (apellido)');
EXPLAIN SELECT * FROM rh.empleado WHERE apellido = 'Silva' LIMIT 5;   SELECT hypopg_reset();
-- Advisor casero y comparativo
SELECT * FROM perf.advisor_findings;   SELECT * FROM perf.advisor_recommendations;
SELECT * FROM perf.v_comparativo ORDER BY 1;
-- Consultas más lentas
SELECT left(query,60) AS q, calls, round(mean_exec_time::numeric,1) AS ms_prom FROM pg_stat_statements ORDER BY mean_exec_time DESC LIMIT 5;
-- Parámetros
SHOW block_size;   SHOW shared_buffers;   SHOW work_mem;
SET work_mem = '64MB';                                    -- solo esta sesión
ALTER SYSTEM SET work_mem = '32MB'; SELECT pg_reload_conf();   -- permanente (shared_buffers requiere "make restart")
```

### Almacenamiento

```sql
\db+
SELECT tablespace, tamano_mb, cuota_mb, uso_pct, estado FROM mant.v_tablespace;
SELECT * FROM mant.fn_verificar_espacio();                -- alerta o autoextiende la cuota
SELECT objeto, tablespace, archivo, tamano FROM mant.v_archivo_datos ORDER BY bytes DESC LIMIT 5;
SELECT pg_size_pretty(pg_tablespace_size('ts_hot')), pg_size_pretty(pg_total_relation_size('rh.empleado'));
SELECT pg_relation_filepath('rh.empleado_2024_2027');     -- el "datafile"
-- Particiones
SELECT * FROM mant.fn_preparar_particiones(3);            -- crea los próximos meses
ALTER TABLE audit.bitacora_2026_11 SET TABLESPACE ts_hot; -- mover (bloquea la tabla)
ALTER TABLE audit.bitacora DETACH PARTITION audit.bitacora_2026_11;     -- desprender
ALTER TABLE audit.bitacora ATTACH PARTITION audit.bitacora_2026_11 FOR VALUES FROM ('2026-11-01') TO ('2026-12-01');
-- Mantenimiento
VACUUM (ANALYZE) rh.asistencia;   REINDEX TABLE CONCURRENTLY rh.asistencia;
SELECT relname, n_dead_tup, last_autovacuum FROM pg_stat_user_tables ORDER BY n_dead_tup DESC LIMIT 5;
-- Nuevo tablespace: antes, en el host:
--   docker exec -u postgres bda-postgres mkdir -p /var/lib/postgresql/tablespaces/ts_prueba
-- (sin volumen propio, queda dentro del disco del contenedor; los 4 reales son volúmenes)
CREATE TABLESPACE ts_prueba LOCATION '/var/lib/postgresql/tablespaces/ts_prueba';
-- pg_cron
SELECT jobname, schedule, command FROM cron.job WHERE jobname LIKE 'bda%';
SELECT cron.schedule('bda_demo', '5 seconds', $$VACUUM (ANALYZE) rh.departamento$$);
SELECT status, return_message FROM cron.job_run_details ORDER BY start_time DESC LIMIT 3;
SELECT cron.unschedule('bda_demo');                       -- siempre al terminar
```

### Datos

```sql
SELECT count(*) FROM rh.empleado;   SELECT count(*) FROM rh.asistencia;
SELECT * FROM rh.vw_resumen_departamento;                 -- cambia según el nivel de quien consulta
SELECT tableoid::regclass AS particion, count(*) FROM rh.empleado GROUP BY 1 ORDER BY 1;
```

## 4. Si algo sale mal

| Síntoma | Qué hacer |
|---|---|
| `make check` con filas que no dicen OK | la columna "remedio" dice qué correr |
| Se quedó una transacción abierta | `ROLLBACK;` |
| Quedó el job `bda_demo` | `SELECT cron.unschedule('bda_demo');` |
| Se corrió `02_esquema.sql` otra vez | volver a correr `03_seguridad.sql` (02 borra los GRANT) |
| Cambió `shared_buffers` | `make restart` |
| `permission denied` en una prueba negativa | es lo esperado; con `\c empleados postgres` se vuelve al superusuario |
| Docker no responde | abrir `evidencias/*.txt` como plan B (tiene la salida completa de cada paso) |

## 5. Preguntas probables

Tabla de respuestas cortas al final de `docs/03_Guion_demo.md` (MAC, SECURITY DEFINER, PK con la columna de partición, `block_size`, Q3, respaldos).
