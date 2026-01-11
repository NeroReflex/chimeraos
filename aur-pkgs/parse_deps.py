#!/usr/bin/env python3
import sys,re
text=sys.stdin.read()
for line in text.splitlines():
    m=re.match(r'^\s*(?:depends(?:_[\w]+)?|makedepends)\s*=\s*(.*)$', line)
    if not m:
        continue
    parts=m.group(1).split()
    for p in parts:
        p=p.strip(',\"\'')
        if p:
            print(p)
