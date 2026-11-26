include .env
export

C = bda-postgres
PSQL = docker exec -i $(C) psql -v ON_ERROR_STOP=1 -U $(POSTGRES_USER) -d $(POSTGRES_DB)

.PHONY: up down psql logs ps reset run
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
