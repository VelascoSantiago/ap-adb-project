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
| 3. Optimización | `sql/04a…04e_*.sql` (`make bloque3` los corre todos) | `evidencias/04a…04e_*.txt` | ✅ |
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

## 4c. Bloque 3 (ya hecho): Optimización

Cinco scripts en orden; **`make bloque3`** reproduce todo desde cero (incluye los dos reinicios necesarios,
unos 5 min). Las mediciones quedan en la tabla `perf.medicion` (de ahí sale el comparativo).

| Script | Qué hace | Qué explicar |
|---|---|---|
| `04a_carga_masiva` | 50 k filas por 3 métodos (con ROLLBACK) y carga definitiva de **500 k empleados + 1 M asistencias** | PL/pgSQL en bucle vs `INSERT…SELECT generate_series` |
| `04b_explain_base` | 5 consultas complejas (`perf.consulta`) y medición **ANTES** con `EXPLAIN (ANALYZE, BUFFERS)` | planes con *Seq Scan* y *Sort* a disco |
| `04c_advisor_indices` | **Advisor casero**, experimento de tipos de índice, índices `CONCURRENTLY`, `REINDEX` | equivalente a `DBA_ADVISOR_*` |
| `04d_parametros` | `block_size` (solo lectura) y ajuste de 5 parámetros con `ALTER SYSTEM` | adaptación de `DB_BLOCK_SIZE` |
| `04e_comparativo` | medición **DESPUÉS** y tabla comparativa de las tres etapas | informe antes/después |

**Carga masiva (50,000 filas, misma máquina):** bucle PL/pgSQL con triggers ≈ 9.5 s (5,200 filas/s);
una sola sentencia con triggers ≈ 5.1 s (9,900/s); una sola sentencia sin el trigger de auditoría ≈ 1.3 s (37,700/s).
Conclusión: el cuello de botella no es solo el bucle, **el trigger de auditoría cuesta ~4x**; en la carga inicial de
500 k se desactivó (y se reactivó) a propósito. Los tiempos absolutos varían entre corridas (el equipo comparte CPU con otros
contenedores); las proporciones se mantienen.

**Las 5 consultas** (`perf.consulta`): Q1 join+agregación, Q2 rango por fecha con *partition pruning*,
Q3 subconsulta + join con asistencia, Q4 función de ventana, Q5 = Q4 reescrita con `LATERAL`.

**Advisor casero** (adaptación, declararlo): `perf.advisor_findings` (lecturas secuenciales, consultas lentas,
sorts a disco, índices sin uso, tuplas muertas; salen de `pg_stat_statements` y `pg_stat_user_*`) y
`perf.advisor_recommendations`, que prueba cada índice candidato **sin crearlo** con `hypopg` y compara el costo
del plan. Umbral: ≥10 % menos costo → CREAR. Incluye un **control negativo** (índice sobre `apellido`) que descarta, y
candidatos combinados (dos índices a la vez). Tras crear los índices reales, el advisor ya no recomienda nada nuevo (6.3).

**Tipos de índice para Q2** (sección 3 de `04c`, 500 k filas):

| Variante | Construcción | Tamaño | Q2 | Nodo |
|---|---|---|---|---|
| sin índice | — | — | 11.3 ms | Seq Scan |
| B-tree simple (fecha) | 265 ms | 3.4 MB | 7.5 ms | Bitmap Index Scan |
| B-tree compuesto (fecha, salario) | 439 ms | 15.1 MB | 5.7 ms | Bitmap Index Scan |
| Parcial (salario > 25000) | 318 ms | 10.2 MB | 5.4 ms | Bitmap Index Scan |
| **Cubriente (INCLUDE)** | 497 ms | 28.6 MB | **3.4 ms** | **Index Only Scan** |

Se eligió el cubriente: es el más rápido pero el más grande (compromiso espacio/velocidad y más costo en escrituras).

**Índices definitivos:** `idx_emp_ingreso_salario`, `idx_emp_depto_salario`, `idx_asis_fecha_empleado`, todos en `ts_idx`.
`CREATE INDEX CONCURRENTLY` **no se admite en tablas particionadas**; la receta (sección 4) es: índice `ON ONLY` en el padre →
`CONCURRENTLY` en cada partición → `ATTACH PARTITION`. Se generan las sentencias con `perf.fn_ddl_indice_concurrente` y se
ejecutan con `\gexec`. También se demuestran `REINDEX INDEX CONCURRENTLY`, mover un índice de tablespace y DROP+CREATE (5.x).

**Parámetros** (`block_size` es **interno, 8 kB, no se puede cambiar**: `ALTER SYSTEM` da error, mostrado en 04d):

| Parámetro | Antes | Después | Por qué |
|---|---|---|---|
| shared_buffers | 128 MB | 512 MB | cabe el *working set*; **requiere reinicio** |
| work_mem | 4 MB | 32 MB | eliminar sorts a disco (4 → 0 `external merge` en los planes) |
| maintenance_work_mem | 64 MB | 256 MB | CREATE INDEX / VACUUM más rápidos |
| effective_cache_size | 4 GB | 2 GB | ajustado a lo que de verdad tiene el contenedor (solo orienta al planificador) |
| random_page_cost | 4 | 1.1 | SSD |

**Comparativo (mejor de 3, caché caliente; ver `04e` sección 3):**

| Consulta | Base | + Índices | + Parámetros | Resultado |
|---|---|---|---|---|
| Q2 rango por fecha | 11.3 ms | 3.5 ms | 3.5 ms | **3.3x**; lecturas 1,484 → 124 buffers; Index Only Scan |
| Q4 ventana | 950 ms | 518 ms | 517 ms | 1.8x; el índice evita el *Sort* pero igual recorre 460 k filas |
| Q5 = Q4 con LATERAL | 452 ms | 0.17 ms | 0.17 ms | **≈2,700x**: reescribir la consulta + índice lee ~100 buffers |
| Q1 join+agregación | 138 ms | 127 ms | 162 ms | **sin mejora real**: ningún índice aplica (lee ~70 % de la tabla); la variación es ruido |
| Q3 subconsulta+join | 152 ms | 237 ms | 230 ms | **empeoró en tiempo** con caché caliente (ver abajo) |

**Hallazgos honestos (incluirlos en la conclusión, el profesor pidió lo logrado y lo no logrado):**
- **Q3:** el costo estimado bajó (59.9 k → 38 k) y los buffers de 23.6 k a 8.4 k (con 7.4 k lecturas de disco antes y ~0 después),
  pero con la caché caliente el plan nuevo (sin paralelismo) no es más rápido. La mejora de Q3 se vería con caché fría o carga concurrente.
  Lección: **costo estimado ≠ tiempo real; hay que validar con `EXPLAIN ANALYZE`.**
- **Q1:** una agregación sobre gran parte de la tabla no se resuelve con índices; ahí ayudaría una vista materializada.
- **Q4 vs Q5:** el mejor "tuning" fue reescribir la consulta, no agregar parámetros.
- Los parámetros por sí solos casi no cambian el tiempo con este volumen (cabe todo en caché); su efecto claro es
  eliminar los sorts a disco y bajar el costo estimado.

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
