#!/bin/bash
# MySQL Router container: bootstrap against the cluster once (retrying until
# the cluster exists), then run. The bootstrap writes the config and creates
# the router's own account in the cluster.
set -euo pipefail
DIR=/var/lib/router
mkdir -p "$DIR" && chown mysqlrouter:mysqlrouter "$DIR"

if [[ ! -f "$DIR/mysqlrouter.conf" ]]; then
    bootstrapped=0
    while (( ! bootstrapped )); do
        for node in node1 node2 node3; do
            if mysqlrouter --bootstrap "clusteradmin:${CLUSTER_ADMIN_PASSWORD}@${node}:3306" \
                    --directory "$DIR" --user=mysqlrouter --force \
                    --conf-bind-address=0.0.0.0 --name=payflow-router; then
                bootstrapped=1; break
            fi
        done
        (( bootstrapped )) || { echo "cluster not ready yet, retrying in 5s"; sleep 5; }
    done
fi
exec mysqlrouter --config "$DIR/mysqlrouter.conf" --user=mysqlrouter
