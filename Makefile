# PayFlow — common tasks. Run `make help` for the list.

SHELL     := /bin/bash
COMPOSE   := docker compose --env-file .env -f docker/standalone/docker-compose.yml
DB        ?= payflow
TEST_DB   ?= payflow_test
TXNS      ?= 10000000
CUSTOMERS ?= 200000

# Runs the mysql client inside the container as root; extra args follow.
MYSQL := $(COMPOSE) exec -T mysql sh -c 'MYSQL_PWD="$$MYSQL_ROOT_PASSWORD" exec mysql -uroot --default-character-set=utf8mb4 "$$@"' mysql

.PHONY: help up down destroy shell generate generate-small schema load triggers setup \
        drop-db test concurrency reconcile workload

help:  ## Show this help
	@grep -E '^[a-zA-Z_.-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

.env:  ## Create .env with a random root password
	@sed "s|^MYSQL_ROOT_PASSWORD=.*|MYSQL_ROOT_PASSWORD=$$(openssl rand -hex 16)|" .env.example > .env
	@echo "Created .env"

# --- container -----------------------------------------------------------------

up: .env  ## Start MySQL and wait until it is healthy
	@mkdir -p data/generated
	$(COMPOSE) up -d --wait

down:  ## Stop MySQL (data volume kept)
	$(COMPOSE) down

destroy:  ## Stop MySQL and DELETE its data volume
	$(COMPOSE) down -v

shell:  ## Interactive mysql prompt on $(DB)
	$(COMPOSE) exec mysql sh -c 'MYSQL_PWD="$$MYSQL_ROOT_PASSWORD" exec mysql -uroot $(DB)'

# --- data ----------------------------------------------------------------------

generate:  ## Generate CSVs (TXNS=10000000 CUSTOMERS=200000)
	python3 scripts/generate_data.py --transactions $(TXNS) --customers $(CUSTOMERS)

generate-small:  ## Generate a 200k-transaction dataset for quick iteration
	python3 scripts/generate_data.py --transactions 200000 --customers 20000

# --- database ------------------------------------------------------------------

schema:  ## Create $(DB) with tables and procedures (fails if it exists)
	@echo "CREATE DATABASE $(DB) CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;" | $(MYSQL) \
		|| { echo "Database $(DB) already exists. Run 'make drop-db' first to rebuild it."; exit 1; }
	$(MYSQL) $(DB) < schema/01_tables.sql
	$(MYSQL) $(DB) < schema/02_procedures.sql

load:  ## Bulk-load data/generated into $(DB)
	scripts/load_data.sh $(DB)

triggers:  ## Apply audit and immutability triggers to $(DB)
	$(MYSQL) $(DB) < schema/03_triggers.sql

setup: schema load triggers  ## schema + load + triggers

drop-db:  ## DROP $(DB) (asks first)
	@read -p "Drop database '$(DB)' and all its data? [y/N] " ans && [[ $$ans == y ]]
	echo "DROP DATABASE IF EXISTS $(DB);" | $(MYSQL)

# --- checks --------------------------------------------------------------------

test:  ## Rebuild $(TEST_DB) and run the procedure/trigger tests
	echo "DROP DATABASE IF EXISTS $(TEST_DB); CREATE DATABASE $(TEST_DB) CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;" | $(MYSQL)
	$(MYSQL) $(TEST_DB) < schema/01_tables.sql
	$(MYSQL) $(TEST_DB) < schema/02_procedures.sql
	$(MYSQL) $(TEST_DB) < schema/03_triggers.sql
	$(MYSQL) $(TEST_DB) --table < schema/tests/test_procedures.sql

concurrency:  ## Hammer sp_transfer_funds from many threads (run `make test` first)
	python3 scripts/concurrency_test.py --database $(TEST_DB)

reconcile:  ## Check ledger invariants on $(DB)
	$(MYSQL) $(DB) --table < schema/queries/reconciliation.sql

workload:  ## Time the reporting queries the tuning phase will optimise
	$(MYSQL) $(DB) --table -vvv < schema/queries/workload.sql
