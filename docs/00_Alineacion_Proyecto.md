# Proyecto BDA — Alineación de requerimientos (Oracle → PostgreSQL + Docker)

**Título:** Diseño, Seguridad y Optimización de un Sistema de Gestión de Empleados
**Profesor:** Mtro. Gerardo Gabriel Carrasco Zúñiga · **Equipo 7** (pareja)
**Base:** PostgreSQL 16 en Docker (mismo enfoque que Prácticas 1–4: red + volúmenes + `docker exec psql`)

## 1. Entorno propuesto

Reemplaza la VM de VirtualBox. Un `docker-compose.yml` con:

- Servicio `postgres` (imagen propia basada en `postgres:16` con `pgaudit`, `pg_cron` y `hypopg` instalados; `shared_preload_libraries = 'pgaudit,pg_cron,pg_stat_statements'`).
- Un volumen por tablespace: `ts_hot`, `ts_warm`, `ts_cold`, `ts_idx` (+ `pgdata`). Es el equivalente a tener varios datafiles en discos distintos.
- Usuario `postgres` como equivalente de `SYS AS SYSDBA`.
- Para la demo: `docker exec -it pg psql -U <rol> -d empleados`, o `\c empleados <rol>`, para cambiar de rol Analista/Administrador/Auditor.

## 2. Requerimiento por requerimiento

| # | Requerimiento Oracle | Equivalente PostgreSQL | Observación / limitación |
|---|---|---|---|
| 1 | Esquema empleados, departamentos, roles | Esquema `rh` con `departamento`, `empleado`, `rol_empleado` (o `puesto`) | Partimos de `SQL_E7_P2_BDA.sql` |
| 1 | Tablas particionadas | `PARTITION BY RANGE (fecha_ingreso)` en `empleado`; `LIST`/`HASH` en otra tabla (p. ej. `bitacora_auditoria` por mes, `asistencia` por hash) | Mostrar al menos 2 estrategias |
| 1 | Múltiples tablespaces | `CREATE TABLESPACE` y asignar **cada partición** a uno distinto; índices en `ts_idx` | Directorios en volúmenes Docker |
| 1 | Vista | `CREATE VIEW` (+ opcional `MATERIALIZED VIEW` con `REFRESH`) | |
| 1 | Trigger de auditoría | Función `PL/pgSQL` + `CREATE TRIGGER ... AFTER INSERT/UPDATE/DELETE` → tabla `audit.bitacora` (usuario, fecha, operación, old/new en `jsonb`) | |
| 2 | Usuarios admin / analista / auditor | `CREATE ROLE ... LOGIN` | Un usuario por integrante + ficticios |
| 2 | Roles personalizados | Roles de grupo `NOLOGIN` (`rol_admin`, `rol_analista`, `rol_auditor`) y `GRANT rol TO usuario` | |
| 2 | DAC | Dueño de la tabla + `GRANT/REVOKE` (`WITH GRANT OPTION`) | Igual que P3 |
| 2 | RBAC | Privilegios solo a roles de grupo; usuarios heredan | Igual que P3 |
| 2 | MAC | **No existe nativo** (sin Oracle Label Security). Aproximación: **Row Level Security** con nivel de clasificación (`nivel_confidencialidad` vs. `clearance` del rol, vía `current_setting`/tabla de niveles) + `REVOKE ... FROM PUBLIC` | Declarar explícitamente que es una aproximación (como en P3) |
| 2 | Pruebas de acceso/modificación/auditoría | Scripts que hacen `SET ROLE`/conexión con cada usuario y muestran permitido/denegado; `pgaudit` para auditoría de sesión/objeto | Evidencia con capturas |
| 3 | PL/SQL inserción masiva ≥ 50,000 | `DO $$ ... $$` PL/pgSQL (loop) y comparar con `INSERT ... SELECT generate_series()` | Medir tiempos de ambos, buen punto para el análisis |
| 3 | `EXPLAIN PLAN` + `DBMS_XPLAN` (≥ 3 queries complejas) | `EXPLAIN (ANALYZE, BUFFERS)`; 3 queries: join + agregación, filtro por rango con *partition pruning*, subconsulta/ventana | Guardar planes antes/después |
| 3 | Modificar/recrear índices | `DROP/CREATE INDEX`, `REINDEX`, B-tree vs. parcial vs. cubriente (`INCLUDE`), `CREATE INDEX CONCURRENTLY` | Comparar `cost` y tiempo real |
| 3 | Ajustar `DB_BLOCK_SIZE` | **`block_size` es de compilación, solo lectura (8 kB).** Se documenta con `SHOW block_size` y se ajustan los equivalentes: `shared_buffers`, `work_mem`, `maintenance_work_mem`, `effective_cache_size`, `random_page_cost` vía `ALTER SYSTEM` + `pg_reload_conf()` | Si se quiere probar otro tamaño: imagen compilada con `--with-blocksize` (opcional, extra) |
| 3 | `DBA_ADVISOR_FINDINGS` / `RECOMMENDATIONS` | **No hay advisor nativo.** Se construye el equivalente: `pg_stat_statements` (queries lentas), `pg_stat_user_tables` (seq scans, dead tuples), `pg_stat_user_indexes` (índices sin uso), `hypopg` (índices hipotéticos). Crear vistas `advisor_findings` y `advisor_recommendations` que los consolidan y aplicar las recomendaciones | Hay que presentarlo como adaptación |
| 4 | Monitorear tablespaces y datafiles | `pg_tablespace_size()`, `pg_total_relation_size()`, `pg_relation_filepath()`, `\db+`; `df -h` en el contenedor | |
| 4 | Autoextensión | **PostgreSQL no tiene datafiles con AUTOEXTEND**: los archivos crecen hasta llenar el volumen. Equivalente: monitoreo + alerta por umbral, límite del volumen (`--storage-opt`/tmpfs size) y creación dinámica de particiones/tablespaces | Declarar la diferencia |
| 4 | Ajustes dinámicos / particiones | Función que crea la partición del siguiente mes; `ALTER TABLE ... SET TABLESPACE`; `DETACH/ATTACH PARTITION` | |
| 4 | Scripts de mantenimiento (truncado, rebuild) | `TRUNCATE` de partición antigua, `REINDEX`, `VACUUM (ANALYZE)`, programados con **`pg_cron`** (o cron del host con `docker exec`) | |
| 5 | Evidencias, comparativo antes/después, informe | Tablas/capturas de `EXPLAIN`, tiempos y parámetros; informe técnico con recomendaciones productivas | |

## 3. Entregables

1. **Presentación PowerPoint** del proceso.
2. **Demo en vivo en Docker** (en lugar de VirtualBox): cambio de rol Analista/Administrador/Auditor, queries que resuelvan dudas del profesor.
3. **Documento final**: pasos detallados, código PL/pgSQL con explicación, queries + resultados explicados, demo, conclusión (logrado / no logrado).
4. Repositorio de scripts numerados (`01_infra`, `02_esquema`, `03_seguridad`, ...) para poder reproducir todo con `docker compose up`.

## 4. Reparto sugerido (pareja)

Ambos definen primero **el modelo de datos y el docker-compose** (paso 0, juntos, para no bloquearse), y luego:

| Persona | Bloques | Entregables |
|---|---|---|
| **Santiago** | **1** Diseño avanzado (esquema, particiones, tablespaces, vista, trigger) + **3** Optimización (carga masiva, EXPLAIN, índices, parámetros, advisor) | Scripts `02`, `04`; sección de diseño y desempeño del documento |
| **Armando** | **2** Seguridad multinivel (usuarios, roles, DAC/RBAC/MAC con RLS, pgaudit, pruebas) + **4** Almacenamiento (monitoreo, particiones dinámicas, mantenimiento con pg_cron) | Scripts `03`, `05`; sección de seguridad y almacenamiento del documento |
| **Ambos** | **5** Auditoría/reporte final, comparativo antes/después, PowerPoint, ensayo de demo | Informe, presentación |

(Asumí que la pareja es la misma de la Práctica 3 — Armando Cruz Maldonado; ajusta si no.) Dependencia: seguridad y mantenimiento necesitan el esquema de 1, por eso el paso 0 conjunto.

## 5. Decisiones abiertas

- ¿Imagen propia (Dockerfile con pgaudit/pg_cron/hypopg) o solo imagen oficial? Recomendado: imagen propia.
- Tamaño de datos: ¿50,000 mínimo o más (p. ej. 500k) para que las diferencias de `EXPLAIN` se noten?
- Cómo presentar MAC (RLS) y el advisor casero: confirmar con el profesor que se acepta como equivalente.
- Fecha de entrega y de presentación (el PDF no las indica).
