REVOKE SELECT, SHOW VIEW, TRIGGER, EVENT ON *.* FROM 'backup'@'%';
GRANT SELECT, SHOW VIEW, TRIGGER, EVENT ON payflow.* TO 'backup'@'%';
GRANT SELECT, SHOW VIEW, TRIGGER, EVENT ON ops.* TO 'backup'@'%';
GRANT SELECT ON performance_schema.log_status TO 'backup'@'%';
GRANT SELECT ON performance_schema.keyring_component_status TO 'backup'@'%';
GRANT SELECT ON performance_schema.replication_group_members TO 'backup'@'%';
GRANT SHOW_ROUTINE ON *.* TO 'backup'@'%';
GRANT SELECT ON mysql.default_roles TO 'backup'@'%';
GRANT SELECT ON mysql.role_edges TO 'backup'@'%';
