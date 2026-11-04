# Pea — Android ARM64 build notes

## Engine / evaluation audit

- UCI Rust engine; the workflow builds only the `Pea` binary, not the separate `filter` tool.
- The active general-purpose evaluation is NNUE (`src/nnue/network.rs`). The old `_hce()` helper in `src/engine/eval.rs` is not called by the search path.
- `src/engine/eval.rs` adds a small handcrafted mop-up bonus for a few sparse mating endings. Search also applies correction-history adjustments. Therefore this is NNUE-based evaluation, not a conventional full NNUE+HCE blend, but it is not strictly NNUE-only in every endgame position.
- Network architecture is `(768 -> 1536) x 2 -> 16 -> 32 -> 1`, with eight output buckets.
- The archive omits `nnue/files/quantised.bin`. Actions first tries the raw network file from the same GitHub repository and branch where the workflow runs (so a copy stored in the user's fork is used automatically), then falls back to `WGCodings/Pea` on `master`. A repository Actions variable named `PEA_NETWORK_URL` can explicitly override the URL. The file is embedded through the existing `include_bytes!` path.

## Android variants

- Android NDK r27c `27.2.12479018`, API 24.
- Rust `1.93.1`, target `aarch64-linux-android`.
- Engine-only UCI executable; no GUI.
- Release / LTO / one codegen unit.
- 16 KB ELF maximum/common page size alignment.
- Baseline ARM64 NEON build uses explicit AArch64 vector code for feature-accumulator updates, feature-transformer activation, and L1 inference.
- Dotprod build uses the same NEON code plus an exact unsigned-byte-by-signed-byte SDOT implementation. The unsigned input is split into 7-bit and high-bit components so the result remains exact; no network re-quantization is performed.
- The workflow disassembles both binaries and fails if the expected NEON vector operations or SDOT instructions are absent.
- Android binaries use the Android NDK/Bionic target, so they depend only on Android system libraries rather than bundling a separate C/C++ runtime.

## Validation boundaries

The workflow validates the network size (9,655,872 bytes), records its SHA-256, checks both ELF files are AArch64, checks instruction generation, and runs a host-side UCI smoke test. A real Android device UCI/search test is still required after downloading the artifacts.
