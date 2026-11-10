#!/usr/bin/env python3
"""Check the exact signed-offset correction used by Pea's ARM SDOT kernel."""
import random

def direct_u8_i8(xs, ws):
    return sum(x * w for x, w in zip(xs, ws))

def signed_offset_sdot(xs, ws):
    # SDOT sees signed bytes, so x is re-encoded as (x - 128).
    # The missing +128*w contribution is restored with 128*sum(w).
    return sum((x - 128) * w for x, w in zip(xs, ws)) + 128 * sum(ws)

edges = [0, 1, 127, 128, 129, 254, 255]
weights = [-128, -127, -1, 0, 1, 126, 127]
for x in edges:
    for w in weights:
        assert direct_u8_i8([x], [w]) == signed_offset_sdot([x], [w])

rng = random.Random(0x504541)
for _ in range(100_000):
    xs = [rng.randrange(256) for _ in range(4)]
    ws = [rng.randrange(-128, 128) for _ in range(4)]
    assert direct_u8_i8(xs, ws) == signed_offset_sdot(xs, ws)

print("PASS: 100,000 randomized u8 x i8 SDOT-correction vectors are bit-exact.")
