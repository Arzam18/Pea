#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TARGET="aarch64-linux-android"
API="${ANDROID_API:-24}"
NDK_HOME="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
NETWORK="${PEA_NETWORK_FILE:-$ROOT/nnue/files/quantised.bin}"
NETWORK_URL="${PEA_NETWORK_URL:-}"
if [[ -z "$NETWORK_URL" && -n "${GITHUB_REPOSITORY:-}" && -n "${GITHUB_REF_NAME:-}" ]]; then
    NETWORK_URL="https://raw.githubusercontent.com/${GITHUB_REPOSITORY}/${GITHUB_REF_NAME}/nnue/files/quantised.bin"
fi
UPSTREAM_NETWORK_URL="https://raw.githubusercontent.com/WGCodings/Pea/master/nnue/files/quantised.bin"
EXPECTED_NETWORK_BYTES=9655872

if [[ -z "$NDK_HOME" || ! -d "$NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin" ]]; then
    echo "ERROR: ANDROID_NDK_HOME is not set to a valid NDK (expected NDK r27c / 27.2.12479018)." >&2
    exit 1
fi
NDK_BIN="$NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
LINKER="$NDK_BIN/aarch64-linux-android${API}-clang"
if [[ ! -x "$LINKER" ]]; then
    echo "ERROR: Android linker not found: $LINKER" >&2
    exit 1
fi

mkdir -p "$(dirname "$NETWORK")"
if [[ ! -s "$NETWORK" ]]; then
    if [[ -n "$NETWORK_URL" ]]; then
        echo "Downloading the Pea NNUE network from the current fork/branch..."
        if ! curl --fail --location --retry 2 --retry-delay 2 "$NETWORK_URL" --output "$NETWORK"; then
            if [[ -n "${PEA_NETWORK_URL:-}" ]]; then
                echo "ERROR: configured PEA_NETWORK_URL could not be downloaded." >&2
                exit 1
            fi
            echo "Fork network not found; falling back to upstream Pea."
            curl --fail --location --retry 4 --retry-delay 2 "$UPSTREAM_NETWORK_URL" --output "$NETWORK"
        fi
    else
        echo "Downloading the upstream Pea NNUE network..."
        curl --fail --location --retry 4 --retry-delay 2 "$UPSTREAM_NETWORK_URL" --output "$NETWORK"
    fi
fi
ACTUAL_BYTES="$(stat -c '%s' "$NETWORK")"
if [[ "$ACTUAL_BYTES" != "$EXPECTED_NETWORK_BYTES" ]]; then
    echo "ERROR: unexpected quantised.bin size: $ACTUAL_BYTES bytes; expected $EXPECTED_NETWORK_BYTES." >&2
    echo "This source expects the Net 0 (1536-hidden) network matching src/nnue/network.rs." >&2
    exit 1
fi
sha256sum "$NETWORK" | tee pea-network.sha256

export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$LINKER"
export CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1
export CARGO_PROFILE_RELEASE_LTO=fat

PAGE_FLAGS="-C link-arg=-Wl,-z,max-page-size=16384 -C link-arg=-Wl,-z,common-page-size=16384"

# Generic ARMv8-A with mandatory AArch64 NEON; Dotprod is deliberately disabled.
export CARGO_TARGET_AARCH64_LINUX_ANDROID_RUSTFLAGS="-C opt-level=3 -C target-cpu=generic -C target-feature=+neon $PAGE_FLAGS"
cargo build --locked --release --bin Pea --target "$TARGET"
cp "target/$TARGET/release/Pea" "Pea-Android-ARM64-NEON"

# Add the explicit SDOT kernel for CPUs with ARMv8.2-A Dotprod (e.g. the user's A16).
export CARGO_TARGET_AARCH64_LINUX_ANDROID_RUSTFLAGS="-C opt-level=3 -C target-cpu=generic -C target-feature=+neon,+dotprod $PAGE_FLAGS"
cargo build --locked --release --bin Pea --target "$TARGET"
cp "target/$TARGET/release/Pea" "Pea-Android-ARM64-DOTPROD"

for BIN in Pea-Android-ARM64-NEON Pea-Android-ARM64-DOTPROD; do
    echo "===== $BIN ====="
    file "$BIN"
    readelf -h "$BIN" | grep -E 'Class:|Data:|Machine:'
    readelf -l "$BIN" | grep -E 'Requesting program interpreter|LOAD' | head -10 || true
    readelf -d "$BIN" | grep NEEDED || true
    sha256sum "$BIN"
done

OBJDUMP="$NDK_BIN/llvm-objdump"
if [[ ! -x "$OBJDUMP" ]]; then
    echo "ERROR: NDK llvm-objdump missing." >&2
    exit 1
fi
if ! "$OBJDUMP" -d Pea-Android-ARM64-DOTPROD | grep -Eq '\bsdot\b'; then
    echo "ERROR: Dotprod binary contains no SDOT instruction." >&2
    exit 1
fi
if ! "$OBJDUMP" -d Pea-Android-ARM64-NEON | grep -Eq '\b(add|smax|smin|smull|sqxtn|sqxtun)\s+v[0-9]+'; then
    echo "ERROR: no expected NEON vector instructions detected in baseline binary." >&2
    exit 1
fi

mkdir -p dist
mv Pea-Android-ARM64-NEON Pea-Android-ARM64-DOTPROD pea-network.sha256 dist/
(
    cd dist
    sha256sum Pea-Android-ARM64-NEON Pea-Android-ARM64-DOTPROD > SHA256SUMS.txt
)
