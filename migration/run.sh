#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .private/migration docs/evidence/phase7
chmod 700 .private/migration
compose=(docker compose --env-file .env -f migration/docker-compose.yml)
lock=.private/migration/run.lock
if ! mkdir "$lock" 2>/dev/null; then
    echo 'Migration already locked; inspect the existing run before retrying.' >&2
    exit 1
fi
# Keep the 4 GB VM free after the drill, retaining isolated volumes for inspection.
cleanup() {
    local status=$?
    "${compose[@]}" stop mysql postgres >/dev/null 2>&1 || true
    rmdir "$lock" 2>/dev/null || true
    return "$status"
}
trap cleanup EXIT
bash migration/tls.sh
"${compose[@]}" up -d --wait mysql postgres
"${compose[@]}" build runner
"${compose[@]}" run --rm --no-deps runner all 2>&1 | tee docs/evidence/phase7/migration-drill.log
"${compose[@]}" run --rm --no-deps --entrypoint python runner -u migration/verify.py 2>&1 | tee docs/evidence/phase7/verification.log
