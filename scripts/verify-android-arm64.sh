#!/usr/bin/env bash
set -euo pipefail

BIN="${1:?Usage: verify-android-arm64.sh <binary> <neon|dotprod>}"
MODE="${2:?Usage: verify-android-arm64.sh <binary> <neon|dotprod>}"
READELF="${ANDROID_READELF:-llvm-readelf}"
OBJDUMP="${ANDROID_OBJDUMP:-llvm-objdump}"

test -s "$BIN"
"$READELF" -h "$BIN" | grep -q 'Class:.*ELF64'
"$READELF" -h "$BIN" | grep -q 'Type:.*DYN'
"$READELF" -h "$BIN" | grep -q 'Machine:.*AArch64'
"$READELF" -l "$BIN" | grep -q '/system/bin/linker64'

if "$READELF" -d "$BIN" | grep -q 'libc++_shared.so'; then
    echo "ERROR: $BIN depends on libc++_shared.so"
    exit 1
fi

DUMP="$(mktemp)"
trap 'rm -f "$DUMP"' EXIT
"$OBJDUMP" -d "$BIN" > "$DUMP"

case "$MODE" in
    neon)
        if ! grep -Eq '\b(smax|smin|smull|sqxtun|uqxtn|add|sub|mul)[[:space:]]+v[0-9]+' "$DUMP"; then
            echo "ERROR: No expected Advanced SIMD instructions found in $BIN"
            exit 1
        fi
        ;;
    dotprod)
        if ! grep -Eq '\bsdot[[:space:]]+v[0-9]+' "$DUMP"; then
            echo "ERROR: No SDOT instruction found in $BIN"
            exit 1
        fi
        ;;
    *)
        echo "ERROR: mode must be 'neon' or 'dotprod'"
        exit 2
        ;;
esac

echo "PASS: $BIN is Android ELF64/AArch64 PIE with /system/bin/linker64."
echo "PASS: $MODE instruction verification."
