# Guía para la documentación del proyecto

Para quien redacta el documento final y el PowerPoint. Aquí está qué hay hecho, dónde está
la evidencia y cómo se mapea a las secciones que pide el profesor. **Se va actualizando
conforme avanzan los bloques prácticos.**

## 1. Cómo obtener todo

1. Clonar el repositorio (el enlace lo pasa quien hace lo práctico).
2. Leer `README.md` (qué es y cómo se levanta) y `docs/00_Alineacion_Proyecto.md` (tabla Oracle → PostgreSQL).
3. No hace falta levantar Docker para documentar: **toda la salida de cada script ya está guardada en `evidencias/`**.
   Si se quiere reproducir: `cp .env.example .env && make up && make run F=sql/02_esquema.sql`.
4. Material de referencia que ya existe (formato y estilo a imitar): las prácticas `Equipo7_Práctica1–4.pdf`
   (cada paso: *Oracle: …* / *PostgreSQL: …* + conclusiones individuales + bibliografía).

## 2. Qué pide el profesor (checklist del documento final)

- [ ] Pasos detallados realizados
- [ ] Programación PL/SQL (aquí **PL/pgSQL**) utilizada, con explicación
- [ ] Queries y resultados con explicación
- [ ] Ejecuciones demo de las acciones más relevantes
- [ ] Conclusión: lo logrado y lo que no se logró (ver sección 5: limitaciones)
- [ ] Informe técnico con conclusiones y recomendaciones para ambientes productivos
- [ ] Análisis comparativo antes/después de la afinación
- [ ] PowerPoint del proceso

## 3. Mapa: bloque → script → evidencia → qué explicar

| Bloque | Script | Evidencia | Estado |
|---|---|---|---|
| Infraestructura | `Dockerfile`, `docker-compose.yml`, `docker/initdb/01_init.sql` | `\db`, `\dx` (captura de terminal) | ✅ |
| 1. Diseño avanzado | `sql/02_esquema.sql` | `evidencias/02_esquema.txt` | ✅ |
| 2. Seguridad | `sql/03_seguridad.sql` | `evidencias/03_seguridad.txt`, `evidencias/03_pgaudit_log.txt` | ✅ |
| 3. Optimización | `sql/04_carga_y_tuning.sql` | `evidencias/04_*.txt` | ⏳ |
| 4. Almacenamiento | `sql/05_almacenamiento.sql` | `evidencias/05_*.txt` | ⏳ |
| 5. Reporte final | — | comparativo antes/después | ⏳ |

## 4. Bloque 1 (ya hecho): qué explicar

**Infraestructura.** Imagen `postgres:16` con tres extensiones que sustituyen herramientas de Oracle:
`pgaudit` (auditoría), `pg_cron` (DBMS_SCHEDULER), `hypopg` (índices hipotéticos, base del "advisor");
`pg_stat_statements` ya viene incluida. Cada tablespace es un **volumen Docker** distinto
(`ts_hot`, `ts_warm`, `ts_cold`, `ts_idx`), equivalente a datafiles en discos distintos.
La VM de VirtualBox se sustituye por contenedores (`docker compose`), según lo acordado.

**Modelo de datos** (esquemas `rh` y `audit`):

| Tabla | Particionamiento | Tablespaces |
|---|---|---|
| `rh.departamento`, `rh.rol_laboral` | — (catálogos) | `ts_hot` |
| `rh.empleado` | **RANGE** por `fecha_ingreso`: `hasta_2019`, `2020_2023`, `2024_2027`, `default` | `ts_cold`, `ts_warm`, `ts_hot`, `ts_hot` |
| `rh.asistencia` | **HASH** por `empleado_id` (4 particiones) | `ts_hot`, `ts_warm`, `ts_cold`, `ts_hot` |
| `audit.bitacora` | **RANGE** mensual (nov-2026, dic-2026, ene-2027, default) | `ts_warm`, `ts_hot`, `ts_hot`, `ts_hot` |
| Índices (PK, UNIQUE) | — | todos en `ts_idx` |

Puntos a destacar en el documento:
- **Dato frío/caliente:** los empleados más antiguos viven en `ts_cold` y los recientes en `ts_hot`.
- **Restricción de PostgreSQL:** la PK de una tabla particionada debe incluir la columna de partición
  (`(empleado_id, fecha_ingreso)`); por eso `asistencia` no tiene FK hacia `empleado`.
- **Partition pruning:** `evidencias/02_esquema.txt` sección 9.4. Una consulta por `fecha_ingreso >= 2025`
  solo lee `empleado_2024_2027` y `empleado_default` (la default siempre se revisa; es un costo
  a mencionar).
- **Vistas:** `vw_resumen_departamento` (agregación) y `vw_empleado_publico` (oculta salario/email; se usa en seguridad).
- **Triggers (PL/pgSQL):**
  - `audit.fn_auditar` → `trg_auditar_empleado` (AFTER INSERT/UPDATE/DELETE): guarda usuario, operación,
    valores old/new en JSONB. Es `SECURITY DEFINER` para que cualquier usuario deje rastro aunque no tenga
    permisos sobre la bitácora; usa `session_user` porque dentro de la función `current_user` sería el dueño.
    Ignora UPDATE que no cambian nada. Equivalente Oracle: trigger con `:OLD`/`:NEW`.
  - `rh.fn_validar_salario` → `trg_validar_salario` (BEFORE INSERT/UPDATE): rechaza salarios fuera del rango del rol.
    Es el "control automático de cambios" del enunciado.
- **Demo del trigger:** sección 9.6 (rechazo) y 9.7 (INSERT/UPDATE/DELETE reflejados en la bitácora).

Capturas sugeridas: salida 9.1 (partición ↔ tablespace), 9.4 (pruning), 9.6 y 9.7 (triggers).

## 4b. Bloque 2 (ya hecho): Seguridad multinivel

Script `sql/03_seguridad.sql` (se ejecuta DESPUÉS de 02; si se vuelve a correr 02 hay que volver a correr 03,
porque los GRANT se pierden al recrear los esquemas). Evidencia: `evidencias/03_seguridad.txt`
(pruebas conectado como cada usuario) y `evidencias/03_pgaudit_log.txt` (log de pgaudit, `make audit-log`).

| Usuario | Rol de grupo | Nivel MAC | Qué puede |
|---|---|---|---|
| `admin_santiago` | `rol_admin` | 3 | CRUD en `rh` (con GRANT OPTION); NO ve la bitácora; sin TRUNCATE |
| `analista_laura` | `rol_analista` | 2 | Lectura; sin la columna `email`; solo filas de nivel ≤ 2 |
| `analista_jr` | `rol_analista` | 1 (excepción por usuario) | Igual que Laura pero solo ve nivel 1 |
| `auditor_armando` | `rol_auditor` | 3 | Solo lectura de todo + `audit.bitacora`; no modifica nada |
| `usuario_sin_rol` | — | 0 | Puede conectarse; todo denegado |

- **RBAC:** los privilegios se dan solo a roles `NOLOGIN` (`rol_*`); los usuarios los heredan por membresía (sección 7.1).
- **DAC:** `GRANT/REVOKE`, `WITH GRANT OPTION` (el admin delega y revoca, 7.4; el analista no puede, 7.2) y permiso **por columna** (analista sin `email`).
- **MAC (adaptación):** no existe Oracle Label Security. Se aproxima con **Row Level Security**: cada fila tiene
  `nivel_confidencialidad` (1–3) y cada sujeto una habilitación en `seg.nivel_acceso` (función `seg.fn_nivel_acceso()`);
  política `mac_lectura` / `mac_escritura` en `rh.empleado` ("no read up"). La habilitación por usuario gana a la del rol
  (caso `analista_jr`). Es una aproximación de Bell-LaPadula, no etiquetas reales: **declararlo**.
- **Detalles que vale explicar:** las particiones no tienen GRANT (consultarlas directo saltaría RLS; probado en 7.2);
  `vw_resumen_departamento` es `security_invoker` (la nómina que ve cada rol cambia según su nivel, 7.2 vs 7.4);
  `vw_empleado_publico` es definer a propósito (expone solo columnas no sensibles); TRUNCATE no se da al admin porque ignora RLS.
- **Separación de funciones:** el admin modifica pero no puede leer ni alterar la auditoría; el auditor lee todo pero no modifica.
- **Auditoría (dos capas):** (1) trigger `audit.fn_auditar` → `audit.bitacora` (valores old/new);
  (2) **pgaudit**: de sesión (`ddl, write, role`) y de objeto (rol `auditoria_obj` con SELECT sobre `salario, email` →
  toda lectura de esas columnas queda en el log). Las líneas incluyen usuario (`log_line_prefix`). pgaudit redacta contraseñas.
- **Nota:** `GRANT` sin permiso no da error sino `WARNING: no privileges were granted` (comportamiento de PostgreSQL, 7.2).
  Los `ERROR: permission denied` del archivo de evidencia son el resultado ESPERADO de las pruebas negativas.
- **Demo:** `docker exec -it bda-postgres psql -U analista_laura -d empleados` (o `SET ROLE analista_laura;` desde postgres, 7.7).
  Contraseñas de demo en el script (solo necesarias por TCP, puerto 5433).

## 5. Diferencias Oracle → PostgreSQL que hay que declarar (honestidad técnica)

El profesor pide conclusión de lo logrado **y lo no logrado**. Estos puntos no son fallas, son adaptaciones:

1. **MAC:** PostgreSQL no tiene Oracle Label Security. Se aproxima con Row Level Security (igual que en la Práctica 3).
2. **`DB_BLOCK_SIZE`:** `block_size` en PostgreSQL es fijo de compilación (8 kB, solo lectura). Se ajustan `shared_buffers`,
   `work_mem`, `effective_cache_size`, `random_page_cost`.
3. **`DBA_ADVISOR_FINDINGS` / `RECOMMENDATIONS`:** no existen. Se construye un equivalente con
   `pg_stat_statements`, `pg_stat_user_tables/indexes` e `hypopg`.
4. **Autoextensión de datafiles:** PostgreSQL no tiene `AUTOEXTEND`. Se sustituye con monitoreo por umbral y
   creación dinámica de particiones.
5. **VirtualBox → Docker:** según acuerdo.

## 6. Convenciones del código (para citarlo)

- Cada script está comentado en español, sección por sección; se puede citar tal cual con su explicación.
- Cada script es re-ejecutable.
- La salida (`evidencias/*.txt`) incluye el SQL ejecutado y su resultado, en orden.
- El contenedor trabaja en UTC; las marcas de tiempo de la bitácora aparecen en UTC.
