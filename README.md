# Diseño, Seguridad y Optimización de un Sistema de Gestión de Empleados

Proyecto final de **Bases de Datos Avanzadas** (UNAM, Facultad de Ingeniería, 2027-1) · Equipo 7.
Prof. Mtro. Gerardo Gabriel Carrasco Zúñiga.

Adaptación del proyecto (planteado para Oracle sobre VirtualBox) a **PostgreSQL 16 en Docker**.
Los requerimientos originales están en `Proyecto BD Avanzadas.pdf` y la tabla de equivalencias
Oracle → PostgreSQL en [`docs/00_Alineacion_Proyecto.md`](docs/00_Alineacion_Proyecto.md).

## Qué incluye

| # | Bloque | Qué se implementa |
|---|---|---|
| 1 | Diseño avanzado | Esquema de empleados/departamentos/roles, tablas particionadas en varios tablespaces, vista y trigger de auditoría |
| 2 | Seguridad multinivel | Usuarios admin/analista/auditor, roles, DAC, RBAC y MAC (aproximado con RLS), pgaudit, pruebas de acceso |
| 3 | Optimización | Carga masiva ≥ 50,000 filas, EXPLAIN de 3 queries, índices, parámetros, "advisor" propio |
| 4 | Almacenamiento | Monitoreo de tablespaces, particiones dinámicas, mantenimiento automático con pg_cron |
| 5 | Auditoría y reporte | Evidencias, comparativo antes/después, informe técnico |

## Requisitos

- Docker y Docker Compose v2
- `make` (opcional, atajos)

## Puesta en marcha

```bash
cp .env.example .env        # ajusta la contraseña si quieres
make up                     # = docker compose up -d --build
make psql                   # consola psql como superusuario
```

Sin `make`: `docker compose up -d --build` y `docker exec -it bda-postgres psql -U postgres -d empleados`.

La primera vez que se crea el volumen se ejecuta `docker/initdb/01_init.sql`, que crea los
tablespaces (`ts_hot`, `ts_warm`, `ts_cold`, `ts_idx`) y las extensiones
(`pg_stat_statements`, `pgaudit`, `pg_cron`, `hypopg`).

> El puerto del host es **5433** por defecto (`PG_PORT` en `.env`) para no chocar con otra
> instancia de PostgreSQL en 5432.

## Ejecutar los scripts

Los scripts de `sql/` se numeran en orden de ejecución. Cada uno se corre y deja su salida
como evidencia en `evidencias/`:

```bash
make run F=sql/02_esquema.sql      # -> evidencias/02_esquema.txt
```

## Estructura

```
.
├── Dockerfile               # postgres:16 + pgaudit, pg_cron, hypopg
├── docker-compose.yml       # servicio, volúmenes (uno por tablespace), red
├── .env.example             # variables (copiar a .env, que no se versiona)
├── Makefile                 # up / down / psql / run / reset
├── docker/initdb/           # infraestructura inicial (tablespaces, extensiones)
├── sql/                     # scripts del proyecto, numerados
├── evidencias/              # salidas de ejecución y capturas
└── docs/                    # alineación, documento final, presentación
```

## Comandos útiles

| Comando | Efecto |
|---|---|
| `make up` / `make down` | Levantar / detener (los datos persisten) |
| `make reset` | **Borra todos los volúmenes** y reinicia desde cero |
| `make logs` | Ver logs de PostgreSQL |
| `make run F=sql/x.sql` | Ejecutar un script y guardar la evidencia |

## Equipo

- Armando Cruz Maldonado
- Santiago Velasco García
