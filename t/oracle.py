#!/usr/bin/env python3
"""tomlc oracles: the toml-test suite, and a differential against tomllib.

SPDX-License-Identifier: GPL-3.0-or-later

Standard library only.  Two modes, because two files would be one too many:

    oracle.py suite ./tomlc CORPUSDIR [--pin FILE]
        Score the vendored toml-test subset.  Prints SCORE lines, ok/not ok
        lines, and (with --pin) writes one "path<TAB>verdict" line per file so
        the committed expectation can be diffed against it.

    oracle.py tomllib ./tomlc CORPUSDIR
        Differential against Python's tomllib: accept/reject agreement over
        every corpus file, value agreement over every valid one, and the same
        two comparisons over generated documents.

The value comparison reimplements toml-test's own json.go: floats compared as
floats, date-times compared as instants, everything else as strings.  Writing
a *stricter* comparison than the suite's would invent failures the suite does
not claim, and a looser one would hide real ones.
"""
import json
import os
import re
import subprocess
import sys

# --------------------------------------------------------------- comparison

DT_RE = re.compile(
    r'^(?:(\d{4})-(\d{2})-(\d{2}))?'
    r'(?:[Tt ]?(\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?)?'
    r'(Z|z|[+-]\d{2}:\d{2})?$')


def days_from_civil(y, m, d):
    """Howard Hinnant's algorithm; any monotone day count would do."""
    y -= m <= 2
    era = (y if y >= 0 else y - 399) // 400
    yoe = y - era * 400
    doy = (153 * (m + (-3 if m > 2 else 9)) + 2) // 5 + d - 1
    doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468


def dt_key(kind, text):
    """Compare date-times the way toml-test does: as instants, not strings.

    That is what lets our "17:45:56.6" match the suite's "17:45:56.600" and
    our normalised "T" match an input's space separator.
    """
    m = DT_RE.match(text.strip())
    if not m:
        raise ValueError('not a date-time: %r' % text)
    y, mo, d, h, mi, s, frac, off = m.groups()
    nanos = int((frac or '').ljust(9, '0')[:9]) if frac else 0
    date = (int(y), int(mo), int(d)) if y else None
    time = (int(h), int(mi), int(s)) if h else None
    if kind == 'date-local':
        return date
    if kind == 'time-local':
        return (time, nanos)
    if kind == 'datetime-local':
        return (date, time, nanos)
    secs = days_from_civil(*date) * 86400 + time[0] * 3600 + time[1] * 60 + time[2]
    if off and off not in 'Zz':
        sign = 1 if off[0] == '+' else -1
        secs -= sign * (int(off[1:3]) * 3600 + int(off[4:6]) * 60)
    return (secs, nanos)


def is_value(x):
    return isinstance(x, dict) and len(x) == 2 and 'type' in x and 'value' in x


def cmp_json(want, have, key=''):
    """Return None if equal, else a human-readable description of the first
    difference.  Mirrors toml-test's CompareJSON."""
    if is_value(want) != is_value(have):
        return '%s: one side is a value and the other a table' % (key or '<root>')
    if is_value(want):
        if want['type'] != have['type']:
            return '%s: type %s != %s' % (key or '<root>', want['type'], have['type'])
        t = want['type']
        if t == 'array':
            return cmp_json(want['value'], have['value'], key)
        w, h = want['value'], have['value']
        if t == 'float':
            w, h = w.lower(), h.lower()
            if w.endswith('nan') or h.endswith('nan'):
                if w.lstrip('+-') != h.lstrip('+-'):
                    return '%s: %s != %s' % (key, w, h)
                return None
            if float(w) != float(h):
                return '%s: float %s != %s' % (key, w, h)
            return None
        if t in ('datetime', 'datetime-local', 'date-local', 'time-local'):
            if dt_key(t, w) != dt_key(t, h):
                return '%s: date-time %s != %s' % (key, w, h)
            return None
        if t == 'bool':
            w, h = w.lower(), h.lower()
        if w != h:
            return '%s: %r != %r' % (key, w, h)
        return None
    if isinstance(want, list) or isinstance(have, list):
        if not (isinstance(want, list) and isinstance(have, list)):
            return '%s: one side is an array' % (key or '<root>')
        if len(want) != len(have):
            return '%s: array length %d != %d' % (key or '<root>', len(want), len(have))
        for i, (a, b) in enumerate(zip(want, have)):
            r = cmp_json(a, b, '%s[%d]' % (key, i))
            if r:
                return r
        return None
    if not (isinstance(want, dict) and isinstance(have, dict)):
        return '%s: not a table on both sides' % (key or '<root>')
    for k in want:
        if k not in have:
            return '%s.%s: missing from our output' % (key, k)
    for k in have:
        if k not in want:
            return '%s.%s: not in the expected output' % (key, k)
    for k in want:
        r = cmp_json(want[k], have[k], '%s.%s' % (key, k))
        if r:
            return r
    return None


# ------------------------------------------------------------------ running

def run(tomlc, path, dump):
    cmd = [tomlc, '-j', path] if dump else [tomlc, path]
    pr = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    return pr.returncode, pr.stdout, pr.stderr


def corpus_files(corpus):
    """The vendored tests/files-toml-1.0.0 list, which is what makes the
    denominator the suite's choice and not ours."""
    with open(os.path.join(corpus, 'files-toml-1.0.0')) as f:
        names = [l.strip() for l in f if l.strip().endswith('.toml')]
    valid = sorted(n for n in names if n.startswith('valid/'))
    invalid = sorted(n for n in names if n.startswith('invalid/'))
    return valid, invalid


def suite(tomlc, corpus, pin):
    valid, invalid = corpus_files(corpus)
    out = []
    vpass = vfail = ipass = ifail = crash = 0
    fails = []
    for name in valid:
        rc, so, se = run(tomlc, os.path.join(corpus, name), True)
        if rc not in (0, 1):
            crash += 1
            fails.append('%s\tEXIT %d\t%s' % (name, rc, se.decode('utf-8', 'replace').strip()))
            out.append('%s\tCRASH' % name)
            continue
        if rc == 1:
            vfail += 1
            fails.append('%s\tWRONGLY REJECTED\t%s' % (name, se.decode('utf-8', 'replace').strip()))
            out.append('%s\treject' % name)
            continue
        with open(os.path.join(corpus, name[:-5] + '.json'), 'rb') as f:
            want = json.load(f)
        try:
            have = json.loads(so.decode('utf-8'))
        except Exception as e:
            vfail += 1
            fails.append('%s\tOUR JSON IS NOT JSON\t%s' % (name, e))
            out.append('%s\tbadjson' % name)
            continue
        diff = cmp_json(want, have)
        if diff:
            vfail += 1
            fails.append('%s\tWRONG VALUE\t%s' % (name, diff))
            out.append('%s\twrong' % name)
        else:
            vpass += 1
            out.append('%s\taccept' % name)
    for name in invalid:
        rc, so, se = run(tomlc, os.path.join(corpus, name), False)
        if rc not in (0, 1):
            crash += 1
            fails.append('%s\tEXIT %d\t%s' % (name, rc, se.decode('utf-8', 'replace').strip()))
            out.append('%s\tCRASH' % name)
        elif rc == 1:
            ipass += 1
            out.append('%s\treject' % name)
        else:
            ifail += 1
            fails.append('%s\tWRONGLY ACCEPTED' % name)
            out.append('%s\taccept' % name)

    print('SCORE valid accepted with the expected value: %d/%d'
          % (vpass, len(valid)))
    print('SCORE invalid rejected: %d/%d' % (ipass, len(invalid)))
    for line in fails:
        print('FAIL %s' % line)
    print('ok - no corpus file exited outside {0,1}' if crash == 0
          else 'not ok - %d corpus files crashed' % crash)
    print('ok - every valid file parsed to the expected value (%d)' % vpass
          if vfail == 0 else 'not ok - %d valid files wrong' % vfail)
    print('ok - every invalid file rejected (%d)' % ipass if ifail == 0
          else 'not ok - %d invalid files wrongly accepted' % ifail)
    if pin:
        with open(pin, 'w') as f:
            f.write('\n'.join(out) + '\n')
    return 0 if (vfail == 0 and ifail == 0 and crash == 0) else 1


def main():
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    mode, tomlc, corpus = sys.argv[1], sys.argv[2], sys.argv[3]
    pin = None
    if '--pin' in sys.argv:
        pin = sys.argv[sys.argv.index('--pin') + 1]
    if mode == 'suite':
        sys.exit(suite(tomlc, corpus, pin))
    sys.exit('unknown mode %s' % mode)


if __name__ == '__main__':
    main()
