#!/usr/bin/env python3
"""Instruction histogram of one assembly routine from build/profile.txt.

Usage: pchist.py SOURCE.s LABEL [--phase N[,N...]] [TOP]
Assembles SOURCE.s with a list file, finds LABEL in build/doom.lst and
counts the profile samples of each source line from LABEL to the next
section directive.
"""
import collections
import re
import subprocess
import sys

src, label = sys.argv[1], sys.argv[2]
rest = sys.argv[3:]
phases = None
if rest[:1] == ['--phase']:
    phases = set(rest[1].split(','))
    rest = rest[2:]
top = int(rest[0]) if rest else 40

lstfile = 'build/pchist.lst'
subprocess.run(['tools/calypsi/bin/as65816', '--code-model=large', '--data-model=medium',
                '-I', 'tools/calypsi/src/lib/lowlevel', '-I', 'build/gen',
                '--list-file', lstfile, '-o', '/tmp/pchist.o', src], check=True)
m = re.search(r'^%s in section \S+\s+placed at address (\w+)-(\w+)' % re.escape(label),
              open('build/doom.lst').read(), re.M)
base, end = int(m.group(1), 16), int(m.group(2), 16)

rows, started = [], False
for line in open(lstfile).read().split('\n'):
    if re.search(r'\b%s:' % re.escape(label), line):
        started = True
    if not started:
        continue
    if '.section' in line and rows:
        break
    m = re.match(r'^\d+\s+([0-9a-f]{6})\s+\S+\s+(.*)$', line)
    if m:
        rows.append((int(m.group(1), 16), m.group(2).strip()))
start = rows[0][0]

counts = collections.Counter()
total = 0
for line in open('build/profile.txt'):
    parts = line.split()
    if phases is not None and (len(parts) < 3 or parts[2] not in phases):
        continue
    pc = int(parts[0], 16)
    if base <= pc <= end:
        off = pc - base + start
        best = None
        for a, text in rows:
            if a <= off:
                best = (a, text)
            else:
                break
        counts[best] += 1
        total += 1
print(f'{total} samples in {label}')
for (a, text), n in sorted(counts.items(), key=lambda kv: -kv[1])[:top]:
    print(f'{100 * n / total:5.1f}% {a:04x} {text}')
