# Shared helpers for the docker/* setup scripts. Source it after setting
# COMPOSE_FILE (path to the compose file the script manages).

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[[ -f "$ROOT/.env" ]] || { echo "No .env: run 'make .env' first." >&2; exit 1; }

# Read one key from .env without sourcing it.
env_value() { grep "^$1=" "$ROOT/.env" | head -1 | cut -d= -f2- | sed 's/[[:space:]]*#.*$//'; }

COMPOSE=(docker compose --env-file "$ROOT/.env" -f "$COMPOSE_FILE")

# sql <service> [mysql args...]  — mysql client as root inside that container.
sql() {
    local svc="$1"; shift
    "${COMPOSE[@]}" exec -T "$svc" sh -c \
        'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -uroot --default-character-set=utf8mb4 "$@"' mysql "$@"
}

# One value from a query, e.g.  q replica1 "SELECT @@server_id"
q() { sql "$1" -N -B -e "$2"; }

# wait_healthy <container> [timeout seconds]
wait_healthy() {
    local name="$1" timeout="${2:-180}" waited=0 state
    while :; do
        state="$(docker inspect -f '{{.State.Health.Status}}' "$name" 2>/dev/null || echo missing)"
        [[ "$state" == healthy ]] && return 0
        (( waited >= timeout )) && { echo "$name not healthy after ${timeout}s (state: $state)" >&2; return 1; }
        sleep 2; waited=$(( waited + 2 ))
    done
}

step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
