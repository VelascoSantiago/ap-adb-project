include .env
export

C = bda-postgres
PSQL = docker exec -i $(C) sh -c 'exec psql -v ON_ERROR_STOP=1 -U $(POSTGRES_USER) -d $(POSTGRES_DB) "$$@" 2>&1' --

.PHONY: up down psql logs ps reset run audit-log restart bloque3 check
up:      ## construye y levanta el contenedor
	docker compose up -d --build
down:    ## detiene (conserva los datos)
	docker compose down
psql:    ## consola interactiva como superusuario
	docker exec -it $(C) psql -U $(POSTGRES_USER) -d $(POSTGRES_DB)
logs:
	docker compose logs -f postgres
ps:
	docker compose ps
reset:   ## BORRA todos los volúmenes y empieza de cero
	docker compose down -v
run:     ## make run F=sql/02_esquema.sql  -> ejecuta y guarda evidencia
	@test -n "$(F)" || (echo "Uso: make run F=sql/archivo.sql"; exit 1)
	@mkdir -p evidencias
	$(PSQL) -a -e < $(F) 2>&1 | tee evidencias/$(basename $(notdir $(F))).txt
audit-log: ## extrae las líneas de pgaudit del log del contenedor -> evidencias/03_pgaudit_log.txt
	@mkdir -p evidencias
	docker logs $(C) 2>&1 | grep 'AUDIT:' | awk '/CREATE ROLE rol_admin /{buf=""} {buf=buf $$0 "\n"} END{printf "%s", buf}' | tee evidencias/03_pgaudit_log.txt
restart: ## reinicia PostgreSQL (necesario tras cambiar shared_buffers) y espera a que esté listo
	docker restart $(C)
	@until docker exec $(C) pg_isready -U $(POSTGRES_USER) -d $(POSTGRES_DB) >/dev/null 2>&1; do sleep 1; done; echo "PostgreSQL listo"
bloque3: ## reproduce TODO el bloque 3 desde cero (02, 03, 04a..04e) con los reinicios necesarios
	$(MAKE) run F=sql/02_esquema.sql
	$(MAKE) run F=sql/03_seguridad.sql
	$(MAKE) run F=sql/04a_carga_masiva.sql
	$(MAKE) restart
	$(MAKE) run F=sql/04b_explain_base.sql
	$(MAKE) run F=sql/04c_advisor_indices.sql
	$(MAKE) run F=sql/04d_parametros.sql
	$(MAKE) restart
	$(MAKE) run F=sql/04e_comparativo.sql
check: ## verifica que todo está listo para la demo (cada fila debe decir OK)
	$(PSQL) < sql/99_verificacion_demo.sql
