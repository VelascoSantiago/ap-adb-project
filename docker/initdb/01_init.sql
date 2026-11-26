-- Se ejecuta UNA vez, al crear el volumen pgdata, conectado a la BD "empleados".
-- Aquí solo va la infraestructura. El esquema y los datos viven en /sql.

-- Tablespaces (los directorios son los volúmenes montados en el contenedor)
CREATE TABLESPACE ts_hot  LOCATION '/var/lib/postgresql/tablespaces/ts_hot';
CREATE TABLESPACE ts_warm LOCATION '/var/lib/postgresql/tablespaces/ts_warm';
CREATE TABLESPACE ts_cold LOCATION '/var/lib/postgresql/tablespaces/ts_cold';
CREATE TABLESPACE ts_idx  LOCATION '/var/lib/postgresql/tablespaces/ts_idx';

-- Extensiones
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS pgaudit;
CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS hypopg;
