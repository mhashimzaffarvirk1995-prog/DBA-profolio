#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
umask 077
mkdir -p .private/tls/server
if [[ -f .private/tls/server/server-key.pem ]]; then
    openssl x509 -checkend 604800 -noout -in .private/tls/server/server-cert.pem
    exit
fi
openssl req -x509 -newkey rsa:3072 -nodes -sha256 -days 3650 -subj '/CN=PayFlow Lab CA' \
    -keyout .private/tls/ca-key.pem -out .private/tls/ca.pem 2>/dev/null
openssl req -newkey rsa:3072 -nodes -sha256 -subj '/CN=mysql' \
    -keyout .private/tls/server/server-key.pem -out .private/tls/server.csr 2>/dev/null
printf '%s\n' 'subjectAltName=DNS:mysql,DNS:recovery,DNS:localhost,IP:127.0.0.1' 'extendedKeyUsage=serverAuth' > .private/tls/server.ext
openssl x509 -req -in .private/tls/server.csr -CA .private/tls/ca.pem -CAkey .private/tls/ca-key.pem \
    -CAcreateserial -CAserial .private/tls/ca.srl -days 365 -sha256 -extfile .private/tls/server.ext \
    -out .private/tls/server/server-cert.pem 2>/dev/null
cp .private/tls/ca.pem .private/tls/server/ca.pem
chmod 644 .private/tls/ca.pem
printf 'Created private CA and SAN certificates (mysql, recovery, localhost, 127.0.0.1)\n'
