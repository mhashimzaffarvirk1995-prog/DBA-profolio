# PayFlow — common tasks. Run `make help` for the list.

SHELL     := /bin/bash
COMPOSE   := docker compose --env-file .env -f docker/standalone/docker-compose.yml
DB        ?= payflow
TEST_DB   ?= payflow_test
TXNS      ?= 10000000
CUSTOMERS ?= 200000
DATA_DIR  ?= data/generated
REPL      := docker compose --env-file .env -f docker/replication/docker-compose.yml
CLUSTER   := docker compose --env-file .env -f docker/cluster/docker-compose.yml

# Runs the mysql client inside the container as root; extra args follow.
MYSQL := $(COMPOSE) exec -T mysql sh -c 'MYSQL_PWD="$$MYSQL_ROOT_PASSWORD" exec mysql -uroot --default-character-set=utf8mb4 "$$@"' mysql

.PHONY: help env up down destroy shell generate generate-small schema load triggers setup \
        drop-db test concurrency reconcile workload \
        repl-up repl-setup repl-status repl-promote repl-down repl-destroy \
        cluster-up cluster-setup cluster-status failover-demo cluster-down cluster-destroy \
        network ops-up ops-setup backup-full backup-logical backup-verify backup-status pitr-drill

help:  ## Show this help
	@grep -E '^[a-zA-Z_.-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

env:  ## Create .env, or add missing keys, with random passwords
	@scripts/ensure_env.sh

.env: env

# --- container -----------------------------------------------------------------

network:  ## Create the Docker network shared by the stacks
	@docker network inspect payflow-shared >/dev/null 2>&1 || docker network create payflow-shared >/dev/null

up: env network  ## Start MySQL and wait until it is healthy
	@mkdir -p data/generated
	$(COMPOSE) up -d --wait mysql

down:  ## Stop MySQL and the ops services (data volume kept)
	$(COMPOSE) --profile ops down

destroy:  ## Stop MySQL and DELETE its data and backup volumes
	$(COMPOSE) --profile ops --profile recovery down -v

shell:  ## Interactive mysql prompt on $(DB)
	$(COMPOSE) exec mysql sh -c 'MYSQL_PWD="$$MYSQL_ROOT_PASSWORD" exec mysql -uroot $(DB)'

# --- data ----------------------------------------------------------------------

generate:  ## Generate CSVs (TXNS=10000000 CUSTOMERS=200000)
	python3 scripts/generate_data.py --transactions $(TXNS) --customers $(CUSTOMERS)

generate-small:  ## 200k-transaction dataset in data/generated-small (Phase 2 labs; or `make load DATA_DIR=...`)
	python3 scripts/generate_data.py --transactions 200000 --customers 20000 --out data/generated-small

# --- database ------------------------------------------------------------------

schema:  ## Create $(DB) with tables and procedures (fails if it exists)
	@echo "CREATE DATABASE $(DB) CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;" | $(MYSQL) \
		|| { echo "Database $(DB) already exists. Run 'make drop-db' first to rebuild it."; exit 1; }
	$(MYSQL) $(DB) < schema/01_tables.sql
	$(MYSQL) $(DB) < schema/02_procedures.sql

load:  ## Bulk-load $(DATA_DIR) into $(DB)
	DATA_DIR=$(DATA_DIR) scripts/load_data.sh $(DB)

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

# --- Phase 2a: classic replication (primary + 2 replicas) ------------------------
# Stop the standalone server first (make down): memory is shared.

data/generated-small/customers.csv:
	$(MAKE) generate-small

repl-up: env data/generated-small/customers.csv  ## Start primary + 2 replicas
	$(REPL) up -d --wait

repl-setup:  ## Load the primary, clone the replicas, start GTID replication
	docker/replication/setup.sh

repl-status:  ## Replication threads, lag and table checksums
	docker/replication/status.sh --checksum

repl-promote:  ## Manual failover: make TARGET (default replica1) the primary
	docker/replication/promote.sh $(or $(TARGET),replica1) --rejoin-old

repl-down:  ## Stop the replication lab (volumes kept)
	$(REPL) down

repl-destroy:  ## Stop the replication lab and DELETE its volumes
	$(REPL) down -v

# --- Phase 2b: InnoDB Cluster + MySQL Router -------------------------------------

cluster-up: env data/generated-small/customers.csv  ## Build tools image, start 3 nodes + router
	$(CLUSTER) up -d --build --wait node1 node2 node3
	$(CLUSTER) up -d tools router

cluster-setup:  ## Load node1, create the cluster with MySQL Shell, wait for Router
	docker/cluster/setup.sh

cluster-status:  ## Members, roles, lag, and where Router routes
	docker/cluster/status.sh

failover-demo:  ## Kill the primary under write load; measure outage, RPO, rejoin
	docker/cluster/failover-demo.sh

cluster-down:  ## Stop the cluster (volumes kept)
	$(CLUSTER) down

cluster-destroy:  ## Stop the cluster and DELETE its volumes
	$(CLUSTER) down -v

# --- Phase 3: backup and disaster recovery (on the standalone server) ------------

ops-setup:  ## Create the backup account and ops.backup_history on $(DB)'s server
	@sed "s|__BACKUP_PASSWORD__|$$(grep '^BACKUP_PASSWORD=' .env | cut -d= -f2)|" backup/setup.sql | $(MYSQL)
	@echo "backup account and ops.backup_history ready"

ops-up: env network  ## Start the ops container (cron backups) and binlog archiver
	$(COMPOSE) --profile ops up -d --build ops binlog-archiver

backup-full:  ## Run the nightly XtraBackup job now
	$(COMPOSE) exec -T ops /ops/full-backup.sh

backup-logical:  ## Run the nightly MySQL Shell dump job now
	$(COMPOSE) exec -T ops /ops/logical-backup.sh

backup-verify:  ## Restore the latest full backup to scratch and check it
	$(COMPOSE) exec -T ops /ops/verify-backup.sh

backup-status:  ## Backup history (evidence trail) and archived binlogs
	@echo "SELECT run_id, job, status, started_at, duration_s AS secs, ROUND(bytes/1048576) AS mb, location FROM ops.backup_history ORDER BY run_id DESC LIMIT 15" | $(MYSQL) --table
	@$(COMPOSE) exec -T ops sh -c 'echo "archived binlogs:"; ls -l /backups/binlogs | tail -n +2 | awk "{print \"  \" \$$9, \$$5}"'

pitr-drill:  ## DR drill: drop a table, restore it to the moment before, measure RTO/RPO
	backup/pitr-drill.sh
