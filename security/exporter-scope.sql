REVOKE SELECT ON *.* FROM 'exporter'@'%';
GRANT SELECT ON performance_schema.* TO 'exporter'@'%';
-- REFERENCES exposes table metadata without permitting row reads or DDL.
GRANT REFERENCES, SHOW VIEW ON payflow.* TO 'exporter'@'%';
GRANT REFERENCES ON ops.* TO 'exporter'@'%';
ALTER USER 'exporter'@'%' REQUIRE SSL;
