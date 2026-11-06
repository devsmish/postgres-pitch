.PHONY: help up down reset logs status leader psql schema migrate migrate-status migrate-verify migrate-test lint lint-ansible failover-test access-test

help:
	@echo "Available targets:"
	@echo "  up             - start the full local stack and wait until the cluster is healthy"
	@echo "  down           - stop and remove the local cluster (keeps volumes)"
	@echo "  reset          - stop and remove the local cluster AND its data"
	@echo "  logs           - tail logs from all cluster containers"
	@echo "  status         - show Patroni cluster member status (patronictl list)"
	@echo "  leader         - show which node is currently the primary"
	@echo "  psql           - open a psql shell against a node (NODE=postgresql0|1|2, default 0)"
	@echo "  migrate        - apply pending schema migrations (Sqitch) to the current primary"
	@echo "  migrate-status - show which migrations are deployed"
	@echo "  migrate-verify - run the verify script of every deployed migration"
	@echo "  lint           - run the pre-commit hooks (all except ansible-lint) against all files"
	@echo "  lint-ansible   - run ansible-lint via its own config (Linux/macOS/WSL only; also runs in CI)"
	@echo "  failover-test  - kill the primary and verify failover end to end (Patroni, HAProxy, roles)"
	@echo "  access-test    - verify HAProxy routing and role-based access (incl. switchover)"
	@echo "  migrate-test   - verify the migrations: baseline equals 001, no-op rerun, privileges, switchover"

up:
	bash docker-compose/bootstrap.sh

down:
	cd docker-compose && docker compose --env-file ../.env down

# DATA_DIR is read from .env WITHOUT sourcing it: sourcing treats the file as shell
# code, which eats the backslashes of a Windows path (D:\DB\pg-pitch becomes
# D:DBpg-pitch) and keeps a trailing carriage return from CRLF line endings, so
# the old recipe "removed" a path that did not exist. Here: take the last
# DATA_DIR= line, drop \r and surrounding quotes, turn backslashes into slashes.
reset:
	cd docker-compose && docker compose --env-file ../.env down
	@cd docker-compose || exit 1; \
	DIR=$$([ -f ../.env ] && grep -E '^[[:space:]]*DATA_DIR=' ../.env | tail -n 1 | cut -d= -f2- | tr -d '\r' | tr '\\' '/'); \
	DIR="$${DIR%\"}"; DIR="$${DIR#\"}"; DIR="$${DIR%\'}"; DIR="$${DIR#\'}"; \
	DIR="$${DIR:-./data}"; \
	case "$$DIR" in "/"|".") echo "Refusing to delete unsafe DATA_DIR: '$$DIR'"; exit 1;; esac; \
	if [ ! -e "$$DIR" ]; then echo "Nothing to remove: '$$DIR' does not exist."; exit 0; fi; \
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

# Schema migrations run as the `sqitch` service of docker-compose.yml (see
# db/migrations/README.md and ADR 0004). -T because deploy/status/verify need no
# terminal, which also keeps them working from Git Bash.
SQITCH = cd docker-compose && docker compose --env-file ../.env run --rm -T sqitch

migrate:
	$(SQITCH) deploy

# `sqitch status` exits 1 when nothing is deployed yet ("No changes deployed"),
# which is a state, not an error; it exits 0 otherwise.
migrate-status:
	$(SQITCH) status || true

migrate-verify:
	$(SQITCH) verify

# Replaced by `make migrate`. It used to apply db/schema/001_initial_schema.sql
# through postgresql0's debug port, which only worked while postgresql0 was the
# primary. Kept as a stub so an old habit gets a clear message.
schema:
	@echo "'make schema' was replaced by 'make migrate' (Sqitch migrations, see db/migrations/README.md)."
	@exit 1

lint:
	pre-commit run --all-files

lint-ansible:
	pre-commit run --all-files -c .pre-commit-config-ansible.yaml

failover-test:
	bash tests/failover_test.sh

access-test:
	bash tests/access_patterns_test.sh

migrate-test:
	bash tests/migrate_test.sh
