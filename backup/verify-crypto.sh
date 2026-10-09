#!/bin/bash
set -euo pipefail
umask 077
source /ops/crypto.sh
work=$(mktemp -d /dev/shm/age-check.XXXXXX)
trap 'rm -rf -- "$work"' EXIT
printf 'synthetic backup secret\n' > "$work/plain"
seal_file "$work/plain" "$work/test.age"
actual=$(age -d -i "$AGE_IDENTITY" "$work/test.age" | sha256sum | cut -d' ' -f1)
expected=$(sha256sum "$work/plain" | cut -d' ' -f1)
[[ "$actual" == "$expected" ]]
echo 'PASS: authenticated backup round trip'
age-keygen -o "$work/wrong-key" 2>/dev/null
if age -d -i "$work/wrong-key" "$work/test.age" >/dev/null 2>&1; then exit 1; fi
echo 'PASS: wrong recovery identity rejected'
cp "$work/test.age" "$work/corrupt.age"
printf 'X' | dd of="$work/corrupt.age" bs=1 seek=190 conv=notrunc status=none
if age -d -i "$AGE_IDENTITY" "$work/corrupt.age" >/dev/null 2>&1; then exit 1; fi
echo 'PASS: tampered backup rejected'
head -c 100 "$work/test.age" > "$work/truncated.age"
if age -d -i "$AGE_IDENTITY" "$work/truncated.age" >/dev/null 2>&1; then exit 1; fi
echo 'PASS: truncated backup rejected'
