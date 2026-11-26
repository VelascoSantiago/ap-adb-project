# PostgreSQL 16 + extensiones que sustituyen herramientas de Oracle:
#   pgaudit            -> auditoría (Oracle Audit)
#   pg_cron            -> DBMS_SCHEDULER (mantenimiento automático)
#   hypopg             -> índices hipotéticos (base del "advisor")
# pg_stat_statements viene incluida en postgresql-contrib de la imagen oficial.
FROM postgres:16

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      postgresql-16-pgaudit \
      postgresql-16-cron \
      postgresql-16-hypopg \
 && rm -rf /var/lib/apt/lists/*

# Directorios de los tablespaces. Al existir en la imagen con dueño postgres,
# los volúmenes nombrados que se montan encima heredan ese dueño.
RUN mkdir -p /var/lib/postgresql/tablespaces/ts_hot \
             /var/lib/postgresql/tablespaces/ts_warm \
             /var/lib/postgresql/tablespaces/ts_cold \
             /var/lib/postgresql/tablespaces/ts_idx \
 && chown -R postgres:postgres /var/lib/postgresql/tablespaces
