-- Monitoring account, created on each server mysqld_exporter probes
-- (`make monitoring-setup`; the password is substituted from .env).
-- Read-only, process list and replication status, at most 3 connections so a
-- misbehaving exporter can never exhaust the server.
CREATE USER IF NOT EXISTS 'exporter'@'%' IDENTIFIED BY '__EXPORTER_PASSWORD__' WITH MAX_USER_CONNECTIONS 3;
GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO 'exporter'@'%';
