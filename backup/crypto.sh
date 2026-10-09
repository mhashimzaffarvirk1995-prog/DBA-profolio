# Authenticated age encryption. Source after lib.sh (private umask already set).
: "${BACKUP_ROOT:=/backups}"
: "${AGE_IDENTITY:=/backup-identity/key.txt}" "${AGE_RECIPIENT:=/backup-public/recipient.txt}"
init_crypto() {
    mkdir -p /backup-identity /backup-public /key-escrow
    chmod 700 /backup-identity /key-escrow
    if [[ ! -s "$AGE_IDENTITY" ]]; then
        age-keygen -o "$AGE_IDENTITY" 2>/dev/null
    fi
    age-keygen -y "$AGE_IDENTITY" > "$AGE_RECIPIENT"
    chmod 600 "$AGE_IDENTITY"
    chmod 644 "$AGE_RECIPIENT"
}
seal_file() {
    local source="$1" dest="${2:-$1.age}"
    rm -f -- "$dest.partial"
    age -R "$AGE_RECIPIENT" -o "$dest.partial" "$source"
    # Verify authentication AND plaintext equality before retiring the source.
    local original recovered
    original=$(sha256sum "$source" | cut -d' ' -f1)
    recovered=$(age -d -i "$AGE_IDENTITY" "$dest.partial" | sha256sum | cut -d' ' -f1)
    [[ "$original" == "$recovered" ]]
    mv -f "$dest.partial" "$dest"
}
seal_tree() {
    local root="$1" file
    while IFS= read -r -d '' file; do
        case "${file##*/}" in
            *.age|*.partial|xtrabackup_binlog_info|keyring.snapshot|sealed.ok) continue ;;
        esac
        seal_file "$file"
        rm -f -- "$file"
    done < <(find "$root" -type f -print0)
    local manifest
    manifest=$(mktemp /dev/shm/backup-manifest.XXXXXX)
    (cd "$root"; find . -type f ! -name 'MANIFEST.age' ! -name 'sealed.ok' ! -name '*.partial' -print0 | sort -z | xargs -0 sha256sum) > "$manifest"
    seal_file "$manifest" "$root/MANIFEST.age"
    rm -f "$manifest"
    printf 'age v1 authenticated files and complete inventory\n' > "$root/sealed.ok"
}
open_tree() {
    local source="$1" target="$2" file relative
    # find does not traverse a command-line symlink such as full/latest.
    source=$(readlink -f "$source")
    [[ -f "$source/sealed.ok" ]] || { echo 'Backup not sealed' >&2; return 1; }
    # The encrypted inventory catches missing whole files and changed metadata,
    # which individual file authentication alone cannot detect.
    age -d -i "$AGE_IDENTITY" "$source/MANIFEST.age" | (cd "$source"; sha256sum -c - >/dev/null)
    mkdir -p "$target"
    chmod 700 "$target"
    while IFS= read -r -d '' file; do
        [[ "${file##*/}" != MANIFEST.age ]] || continue
        relative="${file#"$source"/}"
        mkdir -p "$target/$(dirname "$relative")"
        age -d -i "$AGE_IDENTITY" -o "$target/${relative%.age}.partial" "$file"
        mv "$target/${relative%.age}.partial" "$target/${relative%.age}"
    done < <(find "$source" -type f -name '*.age' -print0)
    if [[ -f "$source/xtrabackup_binlog_info" ]]; then cp "$source/xtrabackup_binlog_info" "$target/"; fi
}
restore_keyring() {
    local source="$1" snapshot
    snapshot=$(cat "$source/keyring.snapshot")
    [[ "$snapshot" =~ ^[0-9TZ]+$ ]] || return 1
    mkdir -p /restore-keyring
    chmod 700 /restore-keyring
    rm -f /restore-keyring/keys.partial
    age -d -i "$AGE_IDENTITY" -o /restore-keyring/keys.partial "/key-escrow/$snapshot.age"
    mv /restore-keyring/keys.partial /restore-keyring/keys
    chown -R mysql:mysql /restore-keyring
    chmod 600 /restore-keyring/keys
}
restore_full() {
    local source="$1" target="$2" stage="$BACKUP_ROOT/restore-stage"
    [[ "$target" == /recovery || "$target" == "$BACKUP_ROOT/verify" ]] || return 1
    [[ ! -e "$stage" ]] || { echo 'restore-stage already exists; inspect before retry' >&2; return 1; }
    restore_keyring "$source"
    open_tree "$source" "$stage"
    [[ -s "$stage/xtrabackup_checkpoints" ]] || { echo 'Restored backup metadata missing' >&2; return 1; }
    printf '%s\n' '{"path":"/restore-keyring/keys","read_only":true}' > "$stage/component_keyring_file.cnf"
    # --move-back retires each staged file as it copies, bounding peak disk use.
    xtrabackup --move-back --target-dir="$stage" --datadir="$target" \
      --component-keyring-config="$stage/component_keyring_file.cnf" > "$target.restore.log" 2>&1
    rm -rf -- "$stage"
    printf '%s\n' '{"components":"file://component_keyring_file"}' > "$target/mysqld.my"
    # Recovery gets a new server UUID and must generate its own encryption keys.
    # Only this escrow-recovered copy is writable; the live keyring is separate.
    printf '%s\n' '{"path":"/restore-keyring/keys","read_only":false}' > "$target/component_keyring_file.cnf"
    # XtraBackup prepare leaves a deliberately empty redo directory. File-only
    # envelope restoration must preserve it: MySQL refuses a missing directory.
    mkdir -p "$target/#innodb_redo"
    chmod 400 "$target/mysqld.my"
    chown -R mysql:mysql "$target"
}
