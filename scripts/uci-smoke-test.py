#!/usr/bin/env python3
"""Run a real depth-2 UCI search and verify bestmove is returned."""
import os
import select
import subprocess
import sys
import time

if len(sys.argv) != 2:
    raise SystemExit(f"usage: {sys.argv[0]} PATH_TO_PEA")

proc = subprocess.Popen(
    [sys.argv[1]],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
    bufsize=0,
)
assert proc.stdin is not None and proc.stdout is not None

os.write(proc.stdin.fileno(), b"uci\nisready\nposition startpos\ngo depth 2\n")
fd = proc.stdout.fileno()
buffer = bytearray()
output = []
seen = set()
deadline = time.monotonic() + 30

try:
    while "bestmove" not in seen:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("No bestmove received within 30 seconds")
        ready, _, _ = select.select([fd], [], [], remaining)
        if not ready:
            raise TimeoutError("No bestmove received within 30 seconds")
        chunk = os.read(fd, 4096)
        if not chunk:
            raise RuntimeError("Pea exited before returning bestmove")
        buffer.extend(chunk)
        while b"\n" in buffer:
            raw_line, _, rest = buffer.partition(b"\n")
            buffer = bytearray(rest)
            line = raw_line.decode("utf-8", errors="replace") + "\n"
            output.append(line)
            stripped = line.strip()
            if stripped in ("uciok", "readyok"):
                seen.add(stripped)
            if stripped.startswith("bestmove "):
                seen.add("bestmove")
                break

    os.write(proc.stdin.fileno(), b"quit\n")
    proc.stdin.close()
    proc.wait(timeout=10)
except Exception:
    proc.kill()
    proc.wait(timeout=5)
    print("".join(output), end="")
    raise

print("".join(output), end="")
for token in ("uciok", "readyok", "bestmove"):
    if token not in seen:
        raise RuntimeError(f"Expected UCI token {token!r} was not returned")
if proc.returncode != 0:
    raise RuntimeError(f"Pea exited with status {proc.returncode}")
