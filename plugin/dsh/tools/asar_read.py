"""Minimal asar reader (stdlib only).

Usage:
  python asar_read.py list  <archive> [substring]
  python asar_read.py cat   <archive> <innerPath>
  python asar_read.py grep  <archive> <regex> [prefix]
"""
import json
import re
import struct
import sys


def load(archive):
    with open(archive, "rb") as handle:
        raw = handle.read()
    # asar: [u32 = 4][u32 pickleSize][u32 jsonSize][json bytes][padding to 4]
    # Locate the JSON document defensively instead of trusting a fixed offset.
    json_size = struct.unpack_from("<I", raw, 8)[0]
    for start in (12, 16, 8):
        chunk = raw[start:start + json_size + 16]
        try:
            text = chunk.decode("utf-8")
        except UnicodeDecodeError:
            continue
        try:
            header, end = json.JSONDecoder().raw_decode(text)
        except json.JSONDecodeError:
            continue
        base = start + len(text[:end].encode("utf-8"))
        while base % 4:
            base += 1
        return raw, header, base
    raise SystemExit("asar: could not locate the header JSON")


def walk(node, prefix, out):
    for name, value in (node.get("files") or {}).items():
        full = f"{prefix}/{name}" if prefix else name
        if "files" in value:
            walk(value, full, out)
        else:
            out.append((full, value))
    return out


def main():
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    mode = sys.argv[1]
    archive = sys.argv[2]
    raw, header, base = load(archive)
    entries = walk(header, "", [])
    if mode == "list":
        needle = sys.argv[3] if len(sys.argv) > 3 else None
        for path, meta in entries:
            if needle is None or needle in path:
                print(f"{meta.get('size')}\t{path}")
    elif mode == "cat":
        want = sys.argv[3].replace("\\", "/")
        for path, meta in entries:
            if path == want:
                start = base + int(meta["offset"])
                sys.stdout.write(raw[start:start + int(meta["size"])].decode("utf-8", "replace"))
                return
        print(f"not found: {want}", file=sys.stderr)
        sys.exit(1)
    elif mode == "grep":
        rx = re.compile(sys.argv[3])
        prefix = sys.argv[4] if len(sys.argv) > 4 else ""
        for path, meta in entries:
            if not path.startswith(prefix):
                continue
            if "offset" not in meta:
                continue
            if path.endswith((".map", ".png", ".jpg", ".ico", ".woff", ".woff2", ".ttf", ".dll", ".exe", ".node", ".wasm", ".zip", ".gz", ".tgz")):
                continue
            start = base + int(meta["offset"])
            try:
                text = raw[start:start + int(meta["size"])].decode("utf-8")
            except UnicodeDecodeError:
                continue
            for index, line in enumerate(text.split("\n"), 1):
                if rx.search(line):
                    print(f"{path}:{index}: {line[:400]}")
    else:
        print(f"unknown mode {mode}", file=sys.stderr)
        sys.exit(2)


main()
