#!/usr/bin/env python3
import sys, json
try:
    from urllib.request import urlopen
    from urllib.parse import quote
except Exception:
    sys.exit(0)

def query(url):
    try:
        with urlopen(url, timeout=10) as r:
            return json.load(r)
    except Exception:
        return {}

if len(sys.argv) < 2:
    sys.exit(0)

name = sys.argv[1]
info = query(f"https://aur.archlinux.org/rpc/?v=5&type=info&arg={quote(name)}")
res = info.get("results")
if isinstance(res, dict):
    print(res.get("Name", ""))
    sys.exit(0)
if isinstance(res, list) and res:
    print(res[0].get("Name", ""))
    sys.exit(0)

search = query(f"https://aur.archlinux.org/rpc/?v=5&type=search&arg={quote(name)}")
arr = search.get("results") or []
if arr:
    print(arr[0].get("Name", ""))
