#!/usr/bin/env bash
# Create .env from .env.example, or add any keys it is missing, with random
# values. Existing values are never changed, so passwords already baked into
# Docker volumes keep working.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
touch "$ROOT/.env"
added=0
while IFS= read -r line; do
    [[ "$line" =~ ^([A-Z_]+)= ]] || continue
    key="${BASH_REMATCH[1]}"
    if ! grep -q "^$key=" "$ROOT/.env"; then
        echo "$key=$(openssl rand -hex 16)" >> "$ROOT/.env"
        echo "Added $key to .env"
        added=1
    fi
done < "$ROOT/.env.example"
chmod 600 "$ROOT/.env"
(( added )) || true
