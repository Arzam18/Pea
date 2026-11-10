#!/usr/bin/env bash
set -euo pipefail

BIN="${1:?Usage: verify-android-arm64.sh <binary> <neon|dotprod>}"
MODE="${2:?Usage: verify-android-arm64.sh <binary> <neon|dotprod>}"
READELF="${ANDROID_READELF:-llvm-readelf}"
OBJDUMP="${ANDROID_OBJDUMP:-llvm-objdump}"

if [[ ! -s "$BIN" ]]; then
    echo "ERROR: Android executable is missing or empty: $BIN" >&2
    exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
HEADER="$TMP_DIR/header.txt"
PROGRAM_HEADERS="$TMP_DIR/program-headers.txt"
DYNAMIC="$TMP_DIR/dynamic.txt"
DISASSEMBLY="$TMP_DIR/disassembly.txt"

# Do not pipe llvm-readelf directly into grep -q under pipefail. Some LLVM
# builds report an output error when grep closes the pipe early. Capturing
# each report first also preserves the tool's real exit status and diagnostics.
echo "Checking ELF header: $BIN"
if "$READELF" -h "$BIN" >"$HEADER"; then
    :
else
    rc=$?
    echo "ERROR: $READELF -h failed for $BIN (exit $rc)." >&2
    exit "$rc"
fi
if ! grep -Eq 'Class:[[:space:]]*ELF64' "$HEADER"; then
    echo "ERROR: $BIN is not ELF64." >&2
    cat "$HEADER" >&2
    exit 1
fi
if ! grep -Eq 'Type:[[:space:]]*DYN' "$HEADER"; then
    echo "ERROR: $BIN is not a PIE/DYN executable." >&2
    cat "$HEADER" >&2
    exit 1
fi
if ! grep -Eq 'Machine:[[:space:]]*AArch64' "$HEADER"; then
    echo "ERROR: $BIN is not an AArch64 executable." >&2
    cat "$HEADER" >&2
    exit 1
fi

echo "Checking Android interpreter"
if "$READELF" -l "$BIN" >"$PROGRAM_HEADERS"; then
    :
else
    rc=$?
    echo "ERROR: $READELF -l failed for $BIN (exit $rc)." >&2
    exit "$rc"
fi
if ! grep -Fq '/system/bin/linker64' "$PROGRAM_HEADERS"; then
    echo "ERROR: $BIN does not request /system/bin/linker64." >&2
    cat "$PROGRAM_HEADERS" >&2
    exit 1
fi

echo "Checking dynamic dependencies"
if "$READELF" -d "$BIN" >"$DYNAMIC"; then
    :
else
    rc=$?
    echo "ERROR: $READELF -d failed for $BIN (exit $rc)." >&2
    exit "$rc"
fi
if grep -Fq 'libc++_shared.so' "$DYNAMIC"; then
    echo "ERROR: $BIN depends on libc++_shared.so" >&2
    cat "$DYNAMIC" >&2
    exit 1
fi

echo "Disassembling executable with $OBJDUMP"
if "$OBJDUMP" -d "$BIN" >"$DISASSEMBLY"; then
    :
else
    rc=$?
    echo "ERROR: $OBJDUMP -d failed for $BIN (exit $rc)." >&2
    exit "$rc"
fi

case "$MODE" in
    neon)
        if ! grep -Eq '\b(smax|smin|smull|sqxtun|uqxtn|add|sub|mul)[[:space:]]+v[0-9]+' "$DISASSEMBLY"; then
            echo "ERROR: No expected Advanced SIMD instructions found in $BIN" >&2
            echo "Sample vector instructions (if any):" >&2
            grep -E '[[:space:]]v[0-9]+\.' "$DISASSEMBLY" | head -20 >&2 || true
            exit 1
        fi
        ;;
    dotprod)
        if ! grep -Eq '\bsdot[[:space:]]+v[0-9]+' "$DISASSEMBLY"; then
            echo "ERROR: No SDOT instruction found in $BIN" >&2
            echo "Sample dot-product/NEON instructions (if any):" >&2
            grep -Ei '\b(sdot|udot|smax|smin|smull)[[:space:]]' "$DISASSEMBLY" | head -20 >&2 || true
            exit 1
        fi
        ;;
    *)
        echo "ERROR: mode must be 'neon' or 'dotprod'" >&2
        exit 2
        ;;
esac

echo "PASS: $BIN is Android ELF64/AArch64 PIE with /system/bin/linker64."
echo "PASS: $MODE instruction verification."
