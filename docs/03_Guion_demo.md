# Guion de demo (≈ 15 min) — Equipo 7

**Reparto sugerido:** Santiago maneja la terminal; Armando explica y lleva el tiempo.
Todo se hace en Docker, sin VirtualBox (mencionarlo al inicio: es la adaptación acordada).

## Antes de empezar (5 min antes, no en vivo)

```bash
systemctl --user start docker-desktop      # esperar a que esté listo
make up && make check                      # las 12 filas deben decir OK; si no, la columna "remedio" dice qué correr
```

Terminales: **T1** como superusuario, **T2** para el log de auditoría, **T3** para cambiar de rol.

```bash
# T1
docker exec -it bda-postgres psql -U postgres -d empleados
# T2 (déjala visible)
docker logs -f --tail 0 bda-postgres 2>&1 | grep --line-buffered AUDIT
# T3 (se reconecta con cada rol)
docker exec -it bda-postgres psql -d empleados -U analista_laura
```

Si algo falla en vivo: `evidencias/*.txt` tiene la salida completa de cada paso; abrirla es un plan B válido.

---

## 1. Entorno y diseño (3 min) — T1

**Decir:** "PostgreSQL 16 en Docker, imagen propia con `pgaudit`, `pg_cron` e `hypopg`. Un volumen por tablespace."

```sql
\db+                                  -- 4 tablespaces: ts_hot, ts_warm, ts_cold, ts_idx
\dx                                   -- extensiones instaladas
SELECT c.relname AS particion, t.spcname AS tablespace, pg_get_expr(c.relpartbound, c.oid) AS limite
FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
LEFT JOIN pg_tablespace t ON t.oid = c.reltablespace
WHERE i.inhparent = 'rh.empleado'::regclass ORDER BY 1;
EXPLAIN (COSTS OFF) SELECT * FROM rh.empleado WHERE fecha_ingreso >= '2025-01-01';   -- partition pruning
```

**Decir:** RANGE por fecha de ingreso (viejos en `ts_cold`, recientes en `ts_hot`), HASH en asistencia, RANGE mensual en la bitácora.
500 mil empleados y 1 millón de asistencias. La consulta solo lee la partición reciente (y la *default*).

**Trigger en vivo** (control de cambios + auditoría):
```sql
UPDATE rh.empleado SET salario = 90000 WHERE email = 'sofia.martinez@empresa.mx';   -- ERROR: fuera del rango del rol Auxiliar
```

## 2. Seguridad multinivel (4 min) — T3 (cambiar de usuario con `\c empleados <usuario>`)

**Analista** (`analista_laura`, nivel 2):
```sql
SELECT current_user, seg.fn_nivel_acceso();
SELECT nivel_confidencialidad, count(*) FROM rh.empleado GROUP BY 1 ORDER BY 1;   -- MAC: no ve el nivel 3
SELECT email FROM rh.empleado LIMIT 1;                  -- DENEGADO (DAC por columna)
UPDATE rh.empleado SET salario = 1;                     -- DENEGADO (RBAC: solo lectura)
SELECT count(*) FROM audit.bitacora;                    -- DENEGADO
```
**Junior** (`\c empleados analista_jr`): mismo rol, **nivel 1** → solo ve 5 filas por MAC por usuario.
**Administrador** (`\c empleados admin_santiago`):
```sql
UPDATE rh.empleado SET salario = 36500 WHERE email = 'elena.flores@empresa.mx';   -- permitido (T2 muestra la línea de pgaudit)
SELECT count(*) FROM audit.bitacora;                    -- DENEGADO: el admin no lee la auditoría (separación de funciones)
GRANT SELECT ON rh.departamento TO usuario_sin_rol;     -- DAC: delega (tiene GRANT OPTION)
REVOKE SELECT ON rh.departamento FROM usuario_sin_rol;
```
**Auditor** (`\c empleados auditor_armando`):
```sql
SELECT usuario, operacion, registro_id, datos_old->>'salario' AS antes, datos_new->>'salario' AS despues
FROM audit.bitacora ORDER BY bitacora_id DESC LIMIT 3;  -- quién cambió qué
UPDATE rh.empleado SET salario = 1;                     -- DENEGADO: el auditor solo lee
```
**Decir:** MAC no existe nativo (no hay Oracle Label Security); se aproxima con **Row Level Security** (política `mac_lectura`/`mac_escritura`)
y niveles por rol/usuario. Es una adaptación declarada. En T2 se ven las líneas de **pgaudit** (escrituras, GRANT/REVOKE y lecturas de salario/email).

## 3. Optimización (4 min) — T1

```sql
SELECT consulta, nombre, ms_base, ms_indices, ms_final, veces_mejor, resultado FROM perf.v_comparativo ORDER BY 1;
```
**Decir:** 5 consultas, 3 etapas. Q2 mejora 3x, Q5 (reescritura con LATERAL) ≈ 2,700x, Q4 1.8x. **Q1 no cambia y Q3 empeoró** en caché caliente:
lo mostramos porque el costo estimado bajó pero el tiempo real no (lección: validar con ANALYZE).

**Antes/después de Q2 en vivo** (los índices se desactivan solo dentro de la transacción):
```sql
BEGIN; SET LOCAL enable_indexscan=off; SET LOCAL enable_indexonlyscan=off; SET LOCAL enable_bitmapscan=off;
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF) SELECT empleado_id, nombre, apellido, salario, fecha_ingreso FROM rh.empleado
 WHERE fecha_ingreso BETWEEN DATE '2025-01-01' AND DATE '2025-06-30' AND salario > 30000 ORDER BY salario DESC LIMIT 50;  -- Seq Scan, ~16 ms
ROLLBACK;
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF) SELECT empleado_id, nombre, apellido, salario, fecha_ingreso FROM rh.empleado
 WHERE fecha_ingreso BETWEEN DATE '2025-01-01' AND DATE '2025-06-30' AND salario > 30000 ORDER BY salario DESC LIMIT 50;  -- Index Only Scan, ~3 ms
```
**Advisor casero** (equivalente a `DBA_ADVISOR_*`):
```sql
SELECT tipo, severidad, left(objeto, 50) AS objeto, detalle FROM perf.advisor_findings ORDER BY 1;
SELECT consulta, accion, mejora_pct, recomendacion FROM perf.advisor_recommendations WHERE tipo = 'INDICE' ORDER BY consulta, mejora_pct DESC;
-- índice hipotético (hypopg): se prueba SIN crearlo
SELECT hypopg_create_index('CREATE INDEX ON rh.empleado (apellido)');
EXPLAIN SELECT * FROM rh.empleado WHERE apellido = 'Silva' LIMIT 5;      -- el planificador "usa" el índice fantasma
SELECT hypopg_reset();
```
**Parámetros y `DB_BLOCK_SIZE`:**
```sql
SHOW block_size;                              -- 8192, fijo de compilación
ALTER SYSTEM SET block_size = 16384;          -- ERROR: no se puede cambiar
SELECT p.nombre, p.valor AS antes, current_setting(p.nombre) AS despues FROM perf.parametro p ORDER BY 1;
```
**Carga masiva:** `SELECT concepto, valor AS ms FROM perf.medicion WHERE etapa='carga' ORDER BY medicion_id;` → bucle 9.5 s, una sentencia 5.1 s, sin trigger de auditoría 1.3 s (50 mil filas).

## 4. Almacenamiento y mantenimiento (3 min) — T1

```sql
SELECT tablespace, tamano_mb, cuota_mb, uso_pct, estado FROM mant.v_tablespace ORDER BY 1;
SELECT objeto, tablespace, archivo, tamano FROM mant.v_archivo_datos ORDER BY bytes DESC LIMIT 5;   -- "datafiles"
```
**Autoextensión lógica y partición nueva, todo dentro de una transacción (no deja rastro):**
```sql
BEGIN;
SELECT * FROM mant.fn_preparar_particiones(3);                                   -- crea la partición del mes siguiente
UPDATE mant.cuota_tablespace SET cuota_mb = ceil(pg_tablespace_size(spcname)/1048576.0/0.90) WHERE spcname='ts_hot';
SELECT tablespace, uso_pct, nivel, accion FROM mant.fn_verificar_espacio() WHERE tablespace='ts_hot';   -- CRITICO → AUTOEXTEND
ROLLBACK;                                                                         -- DDL transaccional: todo vuelve atrás
```
**Decir:** PostgreSQL no tiene AUTOEXTEND (los archivos crecen hasta llenar el disco); el equivalente es monitoreo + cuota lógica + acción
(autoextender, o archivar/mover/purgar). `DETACH`/`ATTACH`, mover de tablespace y `TRUNCATE` están en `evidencias/05_almacenamiento.txt`.
```sql
SELECT jobname, schedule, command FROM cron.job WHERE jobname LIKE 'bda%' ORDER BY 1;   -- 8 jobs (equivale a DBMS_SCHEDULER)
```
**Job en vivo** (cada 5 s, para no esperar al domingo):
```sql
SELECT cron.schedule('bda_demo', '5 seconds', $$VACUUM (ANALYZE) rh.departamento$$);
SELECT pg_sleep(12);
SELECT d.status, d.return_message, d.start_time FROM cron.job_run_details d JOIN cron.job j USING (jobid) WHERE j.jobname = 'bda_demo';
SELECT cron.unschedule('bda_demo');
```

## 5. Cierre (1 min)
Lo logrado, lo adaptado (MAC con RLS, `block_size`, advisor casero, AUTOEXTEND lógico) y lo no logrado (Q1/Q3 sin mejora, sin respaldos/HA).
Detalle en `docs/02_Comparativo_antes_despues.md`, sección 7.

---

## Después de la demo
Si se corrió el job `bda_demo` y no se hizo `unschedule`, o quedó una transacción abierta: `make check` debe volver a dar 12 OK.

## Preguntas probables del profesor (respuestas cortas)

| Pregunta | Respuesta |
|---|---|
| ¿Por qué no Oracle? | Decisión del equipo: PostgreSQL en Docker; `docs/00_Alineacion_Proyecto.md` mapea cada requerimiento Oracle → PostgreSQL. |
| ¿Es MAC de verdad? | No: no hay etiquetas del sistema. RLS aplica la regla "no leer hacia arriba" sin que el dueño del dato la pueda saltar (salvo superusuario/dueño de la tabla). Es una aproximación declarada. |
| ¿Por qué el admin no ve la bitácora? | Separación de funciones: quien modifica no debe poder leer ni alterar la auditoría. |
| ¿Por qué el trigger es `SECURITY DEFINER` y usa `session_user`? | Para que cualquier usuario deje rastro aunque no tenga permiso sobre la bitácora, y para registrar quién es realmente (`current_user` sería el dueño de la función). |
| ¿Por qué la PK de `empleado` incluye `fecha_ingreso`? | PostgreSQL exige que la clave única de una tabla particionada incluya la columna de partición. |
| ¿Se puede cambiar `DB_BLOCK_SIZE`? | No: `block_size` se fija al compilar. Se ajustaron los parámetros que sí influyen (shared_buffers, work_mem, etc.). |
| ¿Por qué Q3 empeoró si el advisor lo recomendó? | El advisor compara costos estimados; el plan nuevo no usa paralelismo y con caché caliente es más lento. Con caché fría reduce lecturas de disco de 7,382 a 1. |
| ¿Cómo se aplicaron los índices sin bloquear? | `CREATE INDEX CONCURRENTLY` por partición + `ON ONLY` en el padre + `ATTACH PARTITION`. |
| ¿Y si se llena un tablespace? | `fn_verificar_espacio` alerta; si hay margen amplía la cuota; si no, se archivan (DETACH) y purgan (TRUNCATE) particiones viejas. |
| ¿Qué pasa con los respaldos? | No se cubrió (fuera del alcance); sería `pg_basebackup` + archivado de WAL para PITR. |
