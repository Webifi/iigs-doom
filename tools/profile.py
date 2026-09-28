#!/usr/bin/env python3
"""Map sampled PCs from build/profile.txt to functions in build/doom.lst.

Usage: profile.py [--phase N[,N...]] [LIST FILE]
Local code blocks (`?Lnnn`) are shown with the C function that holds them.
"""
import bisect
import collections
import functools
import re
import sys

args = sys.argv[1:]
phases = None
if args[:1] == ['--phase']:
    phases = set(args[1].split(','))
    args = args[2:]
lst = open(args[0] if args else 'build/doom.lst').read()


@functools.lru_cache(None)
def asm_lines(obj):
    try:
        return open('build/obj/' + obj.replace('.o', '.s')).read().split('\n')
    except OSError:
        return []


@functools.lru_cache(None)
def owner(label, obj):
    """The function that holds a local label in the assembly source."""
    lines = asm_lines(obj)
    for i, line in enumerate(lines):
        if line.startswith(label + ':'):
            for back in range(i, -1, -1):
                m = re.match(r'^([A-Za-z_]\w*):', lines[back])
                if m:
                    return m.group(1)
    return None
ranges = []
for m in re.finditer(r"^(\S+) in section '(\w+)'\s+placed at address (\w+)-(\w+)[^\n]*\n\((\S+)", lst, re.M):
    if m.group(2) in ('farcode', 'code', 'startup'):
        ranges.append((int(m.group(3), 16), int(m.group(4), 16), m.group(1), m.group(5).split('/')[-1]))
ranges.sort()
starts = [r[0] for r in ranges]


def lookup(pc):
    i = bisect.bisect_right(starts, pc) - 1
    if i >= 0 and ranges[i][0] <= pc <= ranges[i][1]:
        name, obj = ranges[i][2], ranges[i][3]
        if not name.startswith('`?L'):
            return name
        return f'{owner(name, obj) or name}@{obj}'
    return f'?{pc:06X}'


samples = [l.split() for l in open('build/profile.txt')]
if phases is not None:
    samples = [x for x in samples if len(x) > 2 and x[2] in phases]
samples = [x[:2] for x in samples]
funcs = collections.Counter(lookup(int(pc, 16)) for pc, _ in samples)
callers = collections.Counter()
for pc, ret in samples:
    f = lookup(int(pc, 16))
    callers[(f, lookup(int(ret, 16) - 1))] += 1
total = len(samples)
print(f'{total} samples')
for f, n in funcs.most_common(40):
    print(f'{100 * n / total:5.1f}% {f}')
print('\n-- with caller (from stack top, only right in leaf functions) --')
for (f, c), n in callers.most_common(25):
    print(f'{100 * n / total:5.1f}% {f} <- {c}')
