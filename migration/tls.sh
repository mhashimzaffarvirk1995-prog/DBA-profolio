#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash security/create-tls.sh
umask 077
mkdir -p .private/migration/postgres .private/migration/state
if [[ -f .private/migration/postgres/server-key.pem ]]; then
    openssl x509 -checkend 604800 -noout -in .private/migration/postgres/server-cert.pem
    exit
fi
openssl req -newkey rsa:3072 -nodes -sha256 -subj '/CN=postgres' -keyout .private/migration/postgres/server-key.pem -out .private/migration/postgres/server.csr 2>/dev/null
printf '%s\n' 'subjectAltName=DNS:postgres' 'extendedKeyUsage=serverAuth' > .private/migration/postgres/server.ext
openssl x509 -req -in .private/migration/postgres/server.csr -CA .private/tls/ca.pem -CAkey .private/tls/ca-key.pem -CAserial .private/migration/postgres/ca.srl -CAcreateserial -days 365 -sha256 -extfile .private/migration/postgres/server.ext -out .private/migration/postgres/server-cert.pem 2>/dev/null
