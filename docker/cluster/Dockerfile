# MySQL Shell (AdminAPI) and MySQL Router, from Oracle's MySQL 8.4 repos that
# the official server image already has configured.
FROM mysql:8.4
RUN microdnf install -y mysql-shell mysql-router-community \
 && microdnf clean all
