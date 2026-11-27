# Comparativo antes / después y recomendaciones para producción

Fuente de todas las cifras: `evidencias/06_reporte_final.txt` (generado por `sql/06_reporte_final.sql` a partir de la tabla
`perf.medicion`). Reproducible con `make bloque3` y `make run F=sql/05_almacenamiento.sql` y `make run F=sql/06_reporte_final.sql`.

## 1. Metodología (declararla en el documento)

- **Datos:** 500,024 empleados y 1,000,120 asistencias (carga masiva de `04a`), repartidos en particiones y 4 tablespaces.
- **Medición:** `EXPLAIN (ANALYZE, BUFFERS)` de 5 consultas; se toma la **mejor de 3 repeticiones** tras un calentamiento (caché caliente).
- **Tres etapas:** *base* (solo claves primarias, parámetros de fábrica) → *índices* (3 índices nuevos) → *final* (índices + parámetros).
- **Limitación:** el equipo comparte CPU con otros contenedores, así que los tiempos absolutos varían entre corridas (hasta ±50 % en
  consultas cortas). Por eso la sección 4 repite las comparaciones clave **alternando** las variantes en el mismo momento.

## 2. Resultado por consulta

| Consulta | Base | + Índices | + Parámetros | Veredicto |
|---|---|---|---|---|
| **Q1** join + agregación (3 tablas, 71 mil filas por worker) | 138 ms | 127 ms | 162 ms | **Sin cambio real** (ver 4) |
| **Q2** rango por fecha + *pruning* + ORDER BY/LIMIT | 11.3 ms | 3.5 ms | 3.5 ms | **Mejora 3.3x**; buffers 1,484 → 124 |
| **Q3** subconsulta escalar + join con asistencia (1 M filas) | 152 ms | 237 ms | 230 ms | **Empeora 1.6x** en tiempo (ver 4) |
| **Q4** función de ventana (RANK por departamento) | 950 ms | 518 ms | 517 ms | **Mejora 1.8x** |
| **Q5** = Q4 reescrita con `LATERAL` (top-3 por grupo) | 452 ms | 0.17 ms | 0.17 ms | **Mejora ≈ 2,700x**; buffers 45,956 → 105 |

Costo estimado del plan (base → final): Q1 60,082 → 14,820 · Q2 3,433 → 686 · Q3 59,900 → 37,957 · Q4 130,940 → 75,966 · Q5 3,515,256 → 541.
Lecturas de disco (base → final): Q3 7,382 → 1 · Q4 3,291 → 0 · Q5 18,786 → 0.

## 3. Qué cambió y por qué

**Índices (los tres `CONCURRENTLY`, en `ts_idx`):**
- `idx_emp_ingreso_salario (fecha_ingreso, salario DESC) INCLUDE (empleado_id, nombre, apellido)` → Q2 pasa de *Seq Scan* a *Index Only Scan*.
  Se eligió tras comparar 4 variantes: sin índice 11.3 ms · B-tree simple 7.5 ms (3.4 MB) · compuesto 5.7 ms (15.1 MB) · parcial 5.4 ms (10.2 MB) ·
  **cubriente 3.4 ms (28.6 MB)**. Es el más rápido y el más caro en disco y en escrituras.
- `idx_emp_depto_salario (depto_id, salario DESC) INCLUDE (activo)` → entrega las filas ya ordenadas: elimina el *Sort* de Q4 y hace a Q5 instantánea.
- `idx_asis_fecha_empleado (fecha, empleado_id)` → para Q3.

**Parámetros** (`block_size` es interno, fijo en 8 kB; `ALTER SYSTEM SET block_size` da error, evidencia en `04d`):

| Parámetro | Antes | Después | Efecto medido |
|---|---|---|---|
| shared_buffers | 128 MB | 512 MB | acierto de caché; requirió reiniciar |
| work_mem | 4 MB | 32 MB | **ordenamientos a disco (`external merge`): 4 → 0** |
| maintenance_work_mem | 64 MB | 256 MB | CREATE INDEX / VACUUM / REINDEX |
| effective_cache_size | 4 GB | 2 GB | solo orienta al planificador; ajustado a lo que tiene el contenedor |
| random_page_cost | 4 | 1.1 | SSD; baja el costo estimado (Q1: 60 k → 14.8 k) |

Con este volumen todo cabe en caché, así que los parámetros casi no cambian el **tiempo**; su efecto visible es eliminar sorts a disco y bajar costos.

**Carga masiva (50,000 filas):** bucle PL/pgSQL con triggers 9.5 s (5,247 filas/s) · `INSERT…SELECT` con triggers 5.1 s (9,862/s) ·
`INSERT…SELECT` sin trigger de auditoría 1.3 s (37,747/s). El trigger de auditoría cuesta ≈ 4x; el bucle fila por fila, otro ≈ 2x.

## 4. Verificación A/B (sección 9 del reporte; misma hora, 6 repeticiones alternadas)

| Consulta | Con índices (mín / prom) | Sin índices (mín / prom) | Conclusión |
|---|---|---|---|
| Q1 | 61.0 / 68.8 ms | 60.1 / 70.1 ms | **Empate**: ningún índice aplica (lee ~70 % de la tabla). Las diferencias de la sección 2 son ruido. |
| Q2 | 3.5 / 3.6 ms | 10.7 / 11.0 ms | **Los índices ayudan 3x**, confirmado. |
| Q3 | 229.1 / 237.5 ms | 142.5 / 147.6 ms | **Los índices empeoran 1.6x** con caché caliente, confirmado. |

**Q3 en detalle:** el planificador eligió un plan sin paralelismo con *Index Only Scan* (costo 37,957, menor que el 59,900 anterior), pero en la
práctica es más lento que el *Parallel Seq Scan* original. Lo que sí mejoró: buffers 23,661 → 8,373 y lecturas de disco 7,382 → 1,
es decir, **ayuda con caché fría o mucha concurrencia, no con caché caliente**. Moraleja: **el costo estimado no es tiempo real; todo índice
recomendado por un advisor (incluido el casero con `hypopg`) debe validarse con `EXPLAIN ANALYZE`.** El propio advisor recomendó este índice,
y ese es un hallazgo para el informe, no algo que ocultar.

## 5. Almacenamiento y mantenimiento (bloque 4)

Escenarios con datos sintéticos (`evidencias/05_almacenamiento.txt`): `ts_hot` al 89.8 % → autoextensión lógica 173 → 273 MB; `ts_cold` al 91.9 %
sin margen → se archivan 7 particiones (DETACH) y se purgan 4 (TRUNCATE + DROP, 8.9 MB c/u) → 63 %. `VACUUM` deja las 61 mil tuplas muertas por
partición en 0; `VACUUM FULL` reduce una partición de 49 a 31 MB. 8 jobs de `pg_cron` quedan programados.

## 6. Recomendaciones para un ambiente productivo

1. **Validar con medición real, no con costos.** Probar cada índice con `EXPLAIN (ANALYZE, BUFFERS)` en caché fría y caliente antes de desplegarlo (caso Q3).
2. **Índices cubrientes solo para consultas críticas:** Q2 ganó 3x pero el índice pesa 28.6 MB frente a 3.4 MB del simple y encarece cada INSERT/UPDATE.
3. **Reescribir antes de indexar:** Q5 (LATERAL) rindió 2,700x; el índice solo dio 1.8x a la versión con ventana.
4. **Índices en tablas particionadas:** `CREATE INDEX CONCURRENTLY` no se admite en el padre; usar `ON ONLY` + índice por partición + `ATTACH`.
5. **Auditoría:** el trigger de auditoría cuesta ≈ 4x en cargas masivas; para cargas controladas se desactiva temporalmente, para alto volumen
   conviene `pgaudit` hacia un colector externo o un esquema asíncrono. Enviar el log de pgaudit a un sistema aparte (el DBA no debe poder borrarlo).
6. **work_mem es por operación:** `work_mem × operaciones × conexiones` puede agotar la RAM; subirlo por rol o sesión antes que globalmente.
7. **shared_buffers ≈ 25 % de la RAM** del servidor dedicado; `random_page_cost` ≈ 1.1 en SSD; `effective_cache_size` al 50–75 % de la RAM.
8. **Particiones:** automatizar la creación futura (`pg_cron`), no depender de la partición *default* (la poda siempre la revisa y bloquea crear
   rangos con filas dentro), y en producción usar `DETACH PARTITION … CONCURRENTLY`.
9. **Espacio:** los límites de este proyecto son lógicos; en producción vigilar el disco real con un agente externo (Prometheus/node_exporter) y
   alertar antes del 85 %. Planear `VACUUM` regular: un `UPDATE` del 25 % de la tabla la dobló de tamaño hasta que se hizo `VACUUM FULL`.
10. **Seguridad:** sustituir las contraseñas de demostración por un gestor de secretos, restringir `pg_hba.conf`, activar TLS, y revisar el costo de RLS
    (la función de nivel se evalúa una vez por consulta gracias a `(SELECT fn())`).
11. **No cubierto:** respaldo y recuperación (`pg_basebackup`, WAL/PITR), alta disponibilidad y pruebas de concurrencia (`pgbench`). Quedan como trabajo futuro.

## 7. Lo logrado y lo no logrado (para la conclusión)

| Requisito | Estado | Nota |
|---|---|---|
| Esquema, particiones (RANGE y HASH), tablespaces, vista, trigger | ✅ | |
| Usuarios, roles, DAC, RBAC | ✅ | |
| MAC | ⚠️ aproximado | PostgreSQL no tiene Oracle Label Security; se usó Row Level Security |
| Auditoría | ✅ | trigger + pgaudit (sesión y objeto) |
| Inserción masiva ≥ 50,000 filas | ✅ | 500 k, con comparación de 3 métodos |
| EXPLAIN PLAN ≥ 3 consultas, índices, comparativo | ✅ | 5 consultas, 4 variantes de índice |
| Ajuste de `DB_BLOCK_SIZE` | ⚠️ no posible | es de compilación; se ajustaron los parámetros equivalentes |
| Advisor (`DBA_ADVISOR_*`) | ⚠️ casero | `pg_stat_statements` + `hypopg`; se equivocó en Q3 |
| Monitoreo de tablespaces/datafiles | ✅ | |
| Autoextensión | ⚠️ lógica | PostgreSQL no tiene AUTOEXTEND; cuota lógica + función |
| Mantenimiento programado | ✅ | `pg_cron`, 8 jobs |
| Mejora de rendimiento en todas las consultas | ❌ | Q1 sin cambio, Q3 empeoró en caché caliente (documentado) |
