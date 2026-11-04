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
COMMON_RUSTFLAGS="-C opt-level=3 -C target-cpu=generic $PAGE_FLAGS"

# Verify that this Rust toolchain recognizes the AArch64 NEON target feature.
# AArch64 devices have Advanced SIMD, and this check ensures the cfg-selected
# NEON implementations in src/nnue/network.rs are compiled for this target.
NEON_CFG="$(rustc --print cfg --target "$TARGET" $COMMON_RUSTFLAGS -C target-feature=+neon)"
printf '%s\n' "$NEON_CFG" | grep -Fxq 'target_feature="neon"' || {
    echo "ERROR: rustc did not enable target_feature=neon for $TARGET." >&2
    printf '%s\n' "$NEON_CFG" >&2
    exit 1
}

# Separate target directories prevent NEON and Dotprod objects being reused
# across builds. Explicit RUSTFLAGS apply the intended feature to all crates.
export RUSTFLAGS="$COMMON_RUSTFLAGS -C target-feature=+neon"
echo "Building baseline ARM64 NEON; rustc flags: $RUSTFLAGS"
cargo build --locked --release --bin Pea --target "$TARGET" --target-dir "$ROOT/target/android-neon"
cp "$ROOT/target/android-neon/$TARGET/release/Pea" "Pea-Android-ARM64-NEON"

# Confirm rustc activates the Dotprod cfg before compiling the inline SDOT path.
DOTPROD_CFG="$(rustc --print cfg --target "$TARGET" $COMMON_RUSTFLAGS -C target-feature=+neon,+dotprod)"
printf '%s\n' "$DOTPROD_CFG" | grep -Fxq 'target_feature="dotprod"' || {
    echo "ERROR: rustc did not enable target_feature=dotprod for $TARGET." >&2
    printf '%s\n' "$DOTPROD_CFG" >&2
    exit 1
}

export RUSTFLAGS="$COMMON_RUSTFLAGS -C target-feature=+neon,+dotprod"
echo "Building ARM64 Dotprod; rustc flags: $RUSTFLAGS"
cargo build --locked --release --bin Pea --target "$TARGET" --target-dir "$ROOT/target/android-dotprod"
cp "$ROOT/target/android-dotprod/$TARGET/release/Pea" "Pea-Android-ARM64-DOTPROD"

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
NEON_DISASSEMBLY="$(mktemp)"
DOTPROD_DISASSEMBLY="$(mktemp)"
trap 'rm -f "$NEON_DISASSEMBLY" "$DOTPROD_DISASSEMBLY"' EXIT

# Decode the baseline executable with AArch64 Advanced SIMD enabled. Do not
# restrict the check to a short mnemonic list: valid compiler output varies
# (e.g. add/sub/smull/smax/smin/ld1/st1), while vector registers are definitive.
"$OBJDUMP" --mattr=+neon -d Pea-Android-ARM64-NEON > "$NEON_DISASSEMBLY"
NEON_VECTOR_LINES="$(grep -Eic '(^|[[:space:],])v[0-9]{1,2}(\.[0-9]+[bhsd])?([[:space:],]|$)' "$NEON_DISASSEMBLY" || true)"
if [[ "$NEON_VECTOR_LINES" -lt 5 ]]; then
    echo "ERROR: baseline binary has fewer than 5 decoded AArch64 SIMD vector-register instruction lines." >&2
    echo "Detected vector instruction lines: $NEON_VECTOR_LINES" >&2
    echo "First disassembly lines for diagnosis:" >&2
    sed -n '1,100p' "$NEON_DISASSEMBLY" >&2
    exit 1
fi
echo "NEON verification passed: detected $NEON_VECTOR_LINES vector-register instruction lines."
grep -Ei '(^|[[:space:],])v[0-9]{1,2}(\.[0-9]+[bhsd])?([[:space:],]|$)' "$NEON_DISASSEMBLY" | head -8 || true

# Explicitly enable Dotprod decoding, otherwise some LLVM versions show SDOT
# as an unknown word even though it is present in the binary.
"$OBJDUMP" --mattr=+dotprod -d Pea-Android-ARM64-DOTPROD > "$DOTPROD_DISASSEMBLY"
if ! grep -Eiq '[[:space:]]sdot[[:space:]]' "$DOTPROD_DISASSEMBLY"; then
    echo "ERROR: Dotprod binary contains no decoded SDOT instruction (disassembly used --mattr=+dotprod)." >&2
    grep -Ei 'unknown|\.word|dotprod' "$DOTPROD_DISASSEMBLY" | head -20 >&2 || true
    exit 1
fi
echo "Dotprod verification passed: SDOT instruction detected."

mkdir -p dist
mv Pea-Android-ARM64-NEON Pea-Android-ARM64-DOTPROD pea-network.sha256 dist/
(
    cd dist
    sha256sum Pea-Android-ARM64-NEON Pea-Android-ARM64-DOTPROD > SHA256SUMS.txt
)
