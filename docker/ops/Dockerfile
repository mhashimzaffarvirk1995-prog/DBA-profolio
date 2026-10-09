# PayFlow ops toolbox: backup, restore and query-analysis tools on top of the
# same MySQL 8.4 image the servers run (so client versions match).
#   - Percona XtraBackup 8.4  (physical hot backups)
#   - MySQL Shell 8.4         (parallel logical dumps: util.dumpInstance)
#   - Percona Toolkit         (pt-query-digest, pt-table-checksum, ...)
#   - cronie                  (nightly schedule inside the container)
#   - mysqlbinlog             (binlog archiving and point-in-time replay; the
#                              server image's minimal packages leave it out)
FROM mysql:8.4

RUN printf '%s\n' \
      '[percona-pxb-84-lts]' 'name=Percona XtraBackup 8.4 LTS' \
      'baseurl=https://repo.percona.com/pxb-84-lts/yum/release/9/RPMS/$basearch' \
      'enabled=1' 'gpgcheck=1' 'gpgkey=https://repo.percona.com/yum/PERCONA-PACKAGING-KEY' \
      '' \
      '[percona-tools]' 'name=Percona Toolkit' \
      'baseurl=https://repo.percona.com/pt/yum/release/9/RPMS/$basearch' \
      'enabled=1' 'gpgcheck=1' 'gpgkey=https://repo.percona.com/yum/PERCONA-PACKAGING-KEY' \
      > /etc/yum.repos.d/percona.repo \
 && microdnf install -y percona-xtrabackup-84 percona-toolkit mysql-shell cronie zstd procps-ng cpio hostname \
 && microdnf clean all

# mysqlbinlog from the full client package of exactly the server's version.
# Installing that package would clash with the image's server-minimal RPM, so
# only the one binary is extracted.
RUN set -eux; \
    ver="$(rpm -q --qf '%{VERSION}-%{RELEASE}' mysql-community-server-minimal)"; \
    curl -fsSLo /tmp/client.rpm \
      "https://repo.mysql.com/yum/mysql-8.4-community/el/9/$(uname -m)/mysql-community-client-${ver}.$(uname -m).rpm"; \
    cd / && rpm2cpio /tmp/client.rpm | cpio -idm ./usr/bin/mysqlbinlog; \
    rm /tmp/client.rpm; mysqlbinlog --version

ENV LC_ALL=C.UTF-8

# Authenticated streaming encryption, pinned to official release asset digests.
RUN set -eu; arch="$(uname -m)"; \
    case "$arch" in \
      aarch64) age_arch=arm64; digest=c6878a324421b69e3e20b00ba17c04bc5c6dab0030cfe55bf8f68fa8d9e9093a ;; \
      x86_64) age_arch=amd64; digest=bdc69c09cbdd6cf8b1f333d372a1f58247b3a33146406333e30c0f26e8f51377 ;; \
      *) exit 1 ;; esac; \
    curl -fsSL "https://github.com/FiloSottile/age/releases/download/v1.3.1/age-v1.3.1-linux-$age_arch.tar.gz" -o /tmp/age.tar.gz; \
    echo "$digest  /tmp/age.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/age.tar.gz -C /tmp; \
    cp /tmp/age/age /tmp/age/age-keygen /usr/local/bin/; \
    rm -rf /tmp/age /tmp/age.tar.gz

# cmp validates encrypted round trips; flock serializes restore/backup jobs.
RUN microdnf install -y diffutils util-linux && microdnf clean all
