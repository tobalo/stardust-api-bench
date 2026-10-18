#!/usr/bin/env python3
"""Measure a seed import, keeping input size, file allocation and peak RAM separate.

    python3 seed/measure.py <tsv-dir> <database> <import-binary>

Writes seed-metrics.json beside the database, including failed imports. Only the
import subprocess is timed; generation, compilation, hashing and compression
are excluded. File sizes use metadata; the completed seed is hashed after the
import exits, without opening it through the database engine.
"""
import hashlib
import json
import os
import platform
import resource
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path


def file_metrics(path, *, digest=False, rows=False):
    st = path.stat()
    out = {"apparent_bytes": st.st_size, "allocated_bytes": st.st_blocks * 512}
    if digest or rows:
        sha, count, last = hashlib.sha256(), 0, b""
        with path.open("rb") as f:
            for chunk in iter(lambda: f.read(1024 * 1024), b""):
                sha.update(chunk)
                count += chunk.count(b"\n")
                last = chunk[-1:]
        if digest:
            out["sha256"] = sha.hexdigest()
        if rows:
            out["rows"] = count + int(bool(last) and last != b"\n")
    return out


def input_metrics(folder):
    return {name: file_metrics(folder / name, digest=True, rows=True)
            for name in ("users.tsv", "posts.tsv", "likes.tsv")}


def main(argv):
    if len(argv) != 3:
        sys.exit(__doc__)
    source, database, importer = map(Path, argv)
    inputs = input_metrics(source)
    record = {"schema_version": 1, "started_at": datetime.now(timezone.utc).isoformat(),
              "os": platform.system(), "architecture": platform.machine(),
              "inputs": inputs, "tsv_bytes": sum(f["apparent_bytes"] for f in inputs.values()),
              "importer_sha256": file_metrics(importer, digest=True)["sha256"]}
    start = time.monotonic()
    # This fresh Python process has exactly one child. RUSAGE_CHILDREN therefore
    # measures the importer, without a compiler or generator contaminating it.
    code = subprocess.call([str(importer.resolve()), str(source), str(database)])
    elapsed = time.monotonic() - start
    usage = resource.getrusage(resource.RUSAGE_CHILDREN)
    record["import"] = {"exit_code": code, "elapsed_seconds": elapsed,
                        "peak_rss_bytes": int(usage.ru_maxrss * (1 if sys.platform == "darwin" else 1024)),
                        "user_cpu_seconds": usage.ru_utime, "system_cpu_seconds": usage.ru_stime}
    record["database"] = file_metrics(database, digest=code == 0) if database.exists() else None
    path = database.parent / "seed-metrics.json"
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
    os.replace(tmp, path)
    print(f"Seed measurements: {path}", flush=True)
    return code if code >= 0 else 128 - code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
