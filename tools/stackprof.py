#!/usr/bin/env python3
"""Inclusive profile from build/stackprof.txt (tools/probe.lua PROBE_STACKPROF).

Each sample has the PC and the return addresses found on the stack. A
function counts once in a sample if the PC or a return address is in it,
so its share includes everything it calls. The stack scan can find stale
return addresses below the live frames; functions that only show up that
way get a small share too.

Usage: stackprof.py [--phase N[,N...]] [--callers FUNCTION] [LIST FILE]
"""
import collections
import sys

sys.argv, args = sys.argv[:1], sys.argv[1:]
phases = None
callers_of = None
while args and args[0].startswith('--'):
    if args[0] == '--phase':
        phases = set(args[1].split(','))
    elif args[0] == '--callers':
        callers_of = args[1]
    args = args[2:]
if args:
    sys.argv.append(args[0])

import importlib.util  # noqa: E402
spec = importlib.util.spec_from_file_location('profile', __file__.rsplit('/', 1)[0] + '/profile.py')
source = open(spec.origin).read()
# reuse the address lookup of profile.py without running its report
head = source[:source.index("samples = [l.split() for l in open('build/profile.txt')]")]
namespace = {'__file__': spec.origin}
exec(compile(head.replace("args = sys.argv[1:]", "args = []"), spec.origin, 'exec'), namespace)
lookup = namespace['lookup']

samples = []
for line in open('build/stackprof.txt'):
    parts = line.split()
    if phases is not None and parts[1] not in phases:
        continue
    samples.append([int(parts[0], 16)] + [int(a, 16) for a in parts[2:]])

inclusive = collections.Counter()
edges = collections.Counter()
for s in samples:
    names = [lookup(s[0])] + [lookup(a) for a in s[1:]]
    for n in set(names):
        inclusive[n] += 1
    if callers_of:
        for inner, outer in zip(names, names[1:]):
            if inner == callers_of:
                edges[outer] += 1
total = len(samples)
print(f'{total} samples')
if callers_of:
    for n, c in edges.most_common(25):
        print(f'{100 * c / total:5.1f}% {n} -> {callers_of}')
else:
    for n, c in inclusive.most_common(60):
        print(f'{100 * c / total:5.1f}% {n}')
