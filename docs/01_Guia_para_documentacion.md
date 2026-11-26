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
| 2. Seguridad | `sql/03_seguridad.sql` | `evidencias/03_seguridad.txt` | ⏳ |
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
