.PHONY: help up down logs psql schema lint

help:
	@echo "Available targets:"
	@echo "  up      - start the local Docker Compose cluster"
	@echo "  down    - stop and remove the local cluster"
	@echo "  logs    - tail logs from the local cluster"
	@echo "  psql    - open a psql shell against the local primary"
	@echo "  schema  - apply the bootstrap schema to a local database"
	@echo "  lint    - run pre-commit against all files"

up:
	cd docker-compose && docker compose up -d

down:
	cd docker-compose && docker compose down

logs:
	cd docker-compose && docker compose logs -f

psql:
	docker exec -it postgres-pitch-primary psql -U postgres_pitch_admin -d postgres_pitch

schema:
	psql "$${DATABASE_URL:-postgresql://localhost:5432/postgres_pitch}" -f db/schema/001_initial_schema.sql

lint:
	pre-commit run --all-files
