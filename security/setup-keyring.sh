#!/bin/sh
set -eu
# The image probes mysqld as root before dropping privileges; pre-create the
# empty keyring so that probe cannot create a root-owned, unreadable file.
if [ ! -s /keyring/keys ]; then
    printf '%s\n' '{"version":"1.0","elements":[]}' > /keyring/keys
fi
chown -R mysql:mysql /keyring
chmod 700 /keyring
chmod 600 /keyring/keys
