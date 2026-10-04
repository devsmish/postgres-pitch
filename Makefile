.PHONY: help up down reset logs status leader psql schema lint failover-test access-test

help:
	@echo "Available targets:"
	@echo "  up             - start the full local stack and wait until the cluster is healthy"
	@echo "  down           - stop and remove the local cluster (keeps volumes)"
	@echo "  reset          - stop and remove the local cluster AND its data"
	@echo "  logs           - tail logs from all cluster containers"
	@echo "  status         - show Patroni cluster member status (patronictl list)"
	@echo "  leader         - show which node is currently the primary"
	@echo "  psql           - open a psql shell against a node (NODE=postgresql0|1|2, default 0)"
	@echo "  schema         - apply the bootstrap schema to the current primary"
	@echo "  lint           - run pre-commit against all files"
	@echo "  failover-test  - run the automated failover verification script"
	@echo "  access-test    - verify HAProxy routing and role-based access (incl. switchover)"

up:
	bash docker-compose/bootstrap.sh

down:
	cd docker-compose && docker compose --env-file ../.env down

reset:
	cd docker-compose && docker compose --env-file ../.env down
	@cd docker-compose && \
	set -a; [ -f ../.env ] && . ../.env; set +a; \
	DIR="$${DATA_DIR:-./data}"; \
	case "$$DIR" in ""|"/"|".") echo "Refusing to delete unsafe DATA_DIR: '$$DIR'"; exit 1;; esac; \
	echo "Removing local cluster data at: $$DIR"; \
	rm -rf "$$DIR"

logs:
	cd docker-compose && docker compose --env-file ../.env logs -f

status:
	docker exec postgres-pitch-postgresql0 patronictl -c /etc/patroni.yml list

leader:
	@docker exec postgres-pitch-postgresql0 patronictl -c /etc/patroni.yml list \
		| grep Leader || echo "No leader found — is the cluster up? (make status)"

NODE ?= postgresql0
psql:
	docker exec -it postgres-pitch-$(NODE) psql -U $${POSTGRES_USER:-postgres_pitch_admin} -d $${POSTGRES_DB:-postgres_pitch}

schema:
	@echo "Applying schema to the current primary via postgresql0:5433..."
	psql "postgresql://$${POSTGRES_USER:-postgres_pitch_admin}@localhost:5433/$${POSTGRES_DB:-postgres_pitch}" \
		-f db/schema/001_initial_schema.sql

lint:
	pre-commit run --all-files

failover-test:
	bash tests/failover_test.sh

access-test:
	bash tests/access_patterns_test.sh
