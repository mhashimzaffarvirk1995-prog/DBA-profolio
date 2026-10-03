-- =============================================================================
-- Backup infrastructure on the production server (run once by `make ops-setup`,
-- as root; the backup password is substituted in by the Makefile).
--
--   ops.backup_history   one row per backup / verification run: the evidence
--                        trail auditors ask for (Phase 6 reports from it)
--   'backup'@'%'         the only account backup jobs use, with just what
--                        XtraBackup, MySQL Shell dumps and binlog streaming need
-- =============================================================================

CREATE DATABASE IF NOT EXISTS ops CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;

CREATE TABLE IF NOT EXISTS ops.backup_history (
    run_id        BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    job           ENUM('full','logical','verify','pitr_drill') NOT NULL,
    status        ENUM('success','failed') NOT NULL,
    started_at    DATETIME NOT NULL,
    finished_at   DATETIME NOT NULL,
    duration_s    INT UNSIGNED NOT NULL,
    bytes         BIGINT UNSIGNED NOT NULL DEFAULT 0,
    location      VARCHAR(255) NOT NULL,
    details       JSON NULL,
    PRIMARY KEY (run_id),
    KEY idx_job_started (job, started_at)
) ENGINE=InnoDB;

CREATE USER IF NOT EXISTS 'backup'@'%' IDENTIFIED BY '__BACKUP_PASSWORD__' REQUIRE SSL;

-- XtraBackup: backup locks, redo/binlog coordinates, server status
GRANT BACKUP_ADMIN, PROCESS, RELOAD, LOCK TABLES, REPLICATION CLIENT ON *.* TO 'backup'@'%';
GRANT SELECT ON performance_schema.log_status TO 'backup'@'%';
GRANT SELECT ON performance_schema.keyring_component_status TO 'backup'@'%';
GRANT SELECT ON performance_schema.replication_group_members TO 'backup'@'%';
-- MySQL Shell dump: read every object definition and row
GRANT SELECT, SHOW VIEW, TRIGGER, EVENT ON *.* TO 'backup'@'%';
-- binlog archiver: stream binary logs like a replica
GRANT REPLICATION SLAVE ON *.* TO 'backup'@'%';
-- evidence trail
GRANT INSERT ON ops.backup_history TO 'backup'@'%';
