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


# ------------------------------------------------- the tomllib differential

def project(x):
    """Project a tomllib value into toml-test's tagged encoding."""
    import datetime
    if isinstance(x, dict):
        return {k: project(v) for k, v in x.items()}
    if isinstance(x, list):
        return [project(v) for v in x]
    if isinstance(x, str):
        return {'type': 'string', 'value': x}
    if isinstance(x, bool):
        return {'type': 'bool', 'value': 'true' if x else 'false'}
    if isinstance(x, int):
        return {'type': 'integer', 'value': str(x)}
    if isinstance(x, float):
        if x != x:
            return {'type': 'float', 'value': 'nan'}
        if x in (float('inf'), float('-inf')):
            return {'type': 'float', 'value': 'inf' if x > 0 else '-inf'}
        return {'type': 'float', 'value': repr(x)}
    if isinstance(x, datetime.datetime):
        kind = 'datetime' if x.tzinfo is not None else 'datetime-local'
        return {'type': kind, 'value': x.isoformat()}
    if isinstance(x, datetime.date):
        return {'type': 'date-local', 'value': x.isoformat()}
    if isinstance(x, datetime.time):
        return {'type': 'time-local', 'value': x.isoformat()}
    raise TypeError('unexpected tomllib type %r' % type(x))


def py_parse(data):
    """(ok, projected) for tomllib on these bytes."""
    import tomllib
    try:
        return True, project(tomllib.loads(data.decode('utf-8')))
    except UnicodeDecodeError:
        return False, None
    except tomllib.TOMLDecodeError:
        return False, None
    except (ValueError, OverflowError, RecursionError):
        # A date-time tomllib accepts syntactically but datetime cannot
        # represent raises ValueError from the constructor.
        return False, None


CRASHED = object()   # distinguishable from both True and False


def our_parse(tomlc, path):
    """(accepted, value), or (CRASHED, status) if tomlc did neither.

    The third outcome is the point. This used to return (False, None) for
    any nonzero status, so a SIGSEGV or an ASan abort on an invalid
    document was indistinguishable from a clean rejection -- tomllib
    rejects it too, the verdicts "agree", and the crash is counted as
    agreement. suite() has always got this right (`if rc not in (0, 1)`);
    the differential did not, and the differential is the only thing that
    sees the 17 edge documents and the 180 generated and byte-mutated ones.
    Those 60 mutated documents are the only inputs here nobody chose, which
    makes this the one place a crash was most likely to appear and least
    likely to be noticed.
    """
    rc, so, se = run(tomlc, path, True)
    if rc == 0:
        return True, json.loads(so.decode('utf-8'))
    if rc == 1:
        return False, None
    return CRASHED, rc


# Documents whose edges the corpus does not reach.  Each one is here because
# it is a place two conforming parsers may legitimately differ.
EDGES = [
    ('a = 23:59:60\n', 'leap second'),
    ('a = 1990-12-31T23:59:60Z\n', 'leap second with an offset'),
    ('a = 9223372036854775808\n', 'int64 max plus one'),
    ('a = -9223372036854775809\n', 'int64 min minus one'),
    ('a = 0xffffffffffffffff\n', 'unsigned 64-bit max in hex'),
    ('a = 1e400\n', 'float overflow'),
    ('a = 1e-400\n', 'float underflow'),
    ('a = 00:32:00.9999999\n', 'seven fractional digits'),
    ('a = 1979-05-27T00:32:00.999999999999Z\n', 'twelve fractional digits'),
    ('a = "\\u0000"\n', 'an escaped NUL in a string'),
    # BYTES, not a str. As a str this is five characters that encode to six
    # bytes of mojibake (c3 af c2 bb c2 bf ...), which both parsers reject as
    # a bad key -- so it scored as agreement and tested nothing about BOMs.
    # The loop below already honours a bytes entry.
    (b'\xef\xbb\xbfa = 1\n', 'a leading UTF-8 BOM'),
    ('a = """x\r\ny"""\n', 'a CRLF inside a multi-line string'),
    ('a = -0.0\n', 'negative zero float'),
    ('a = -0\n', 'negative zero integer'),
    ('a = -nan\n', 'a signed nan'),
    ('a = ' + '['*60 + ']'*60 + '\n', 'sixty nested arrays'),
    ('a = ' + '['*300 + ']'*300 + '\n', 'three hundred nested arrays'),
]


def gen_docs(n):
    """Deterministic pseudo-random documents.  Not a fuzzer: the point is to
    cover value shapes nobody wrote a test for, and the mutations to cover
    rejection agreement on inputs nobody wrote a test for either."""
    import random
    rng = random.Random(20261009)
    scalars = [
        '0', '-1', '+7', '1_000', '0xdead_beef', '0o755', '0b1010',
        '9223372036854775807', '-9223372036854775808',
        '0.0', '-0.0', '3.14', '1e10', '-1E-10', '6.02e23', 'inf', '-inf',
        'nan', 'true', 'false',
        '"s"', '""', '"a\\tb"', '"\\u00e9"', '"\\U0001F600"', "'lit'", "''",
        '"""ml\nstring"""', "'''ml\nlit'''", '"""a\\\n   b"""',
        '1979-05-27T07:32:00Z', '1979-05-27 07:32:00-07:00',
        '1979-05-27T07:32:00.123', '1979-05-27', '07:32:00',
        '[]', '[1, 2, 3]', '[[1], ["a"], [[]]]', '{}', '{x = 1, y.z = 2}',
        '[{a = 1}, {a = 2}]',
    ]
    keys = ['a', 'b', 'key-1', 'key_2', '"q k"', "'l k'", '"\\u00e9"', '1', '""']
    docs = []
    for i in range(n):
        lines = []
        for _ in range(rng.randrange(1, 6)):
            lines.append('%s = %s' % (rng.choice(keys), rng.choice(scalars)))
        for _ in range(rng.randrange(0, 4)):
            style = rng.randrange(3)
            name = '%s.%s' % (rng.choice(['t', 'u', 'v']), rng.choice(['x', 'y']))
            if style == 0:
                lines.append('[%s]' % name)
            elif style == 1:
                lines.append('[[%s]]' % name)
            else:
                lines.append('%s = %s' % (name, rng.choice(scalars)))
            for _ in range(rng.randrange(0, 3)):
                lines.append('%s = %s' % (rng.choice(keys), rng.choice(scalars)))
        doc = '\n'.join(lines) + '\n'
        docs.append(('gen-%03d' % i, doc))
    # Mutations: a byte flipped, inserted or dropped.  Most of these are
    # invalid, which is the point -- rejection has to agree too.
    base = [d for _, d in docs[:60]]
    for i, d in enumerate(base):
        if not d:
            continue
        pos = rng.randrange(len(d))
        kind = rng.randrange(3)
        if kind == 0:
            m = d[:pos] + chr(rng.randrange(32, 127)) + d[pos + 1:]
        elif kind == 1:
            m = d[:pos] + rng.choice('[]{}.,="\'#\\\n\t') + d[pos:]
        else:
            m = d[:pos] + d[pos + 1:]
        docs.append(('mut-%03d' % i, m))
    return docs


def tomllib_mode(tomlc, corpus, pin):
    scratch = os.path.join(os.path.dirname(corpus), 'py')
    os.makedirs(scratch, exist_ok=True)
    tmp = os.path.join(scratch, 'doc.toml')
    valid, invalid = corpus_files(corpus)
    verdict_same = verdict_diff = value_same = value_diff = 0
    crashed = 0
    div = []

    def one(label, path, data, want_json=None):
        nonlocal verdict_same, verdict_diff, value_same, value_diff, crashed
        ours, oval = our_parse(tomlc, path)
        theirs, tval = py_parse(data)
        if ours is CRASHED:
            # Counted separately and never as agreement. `ours == theirs`
            # would have been False here either way, which is why the old
            # two-outcome version folded a crash on an invalid document
            # into "both rejected it".
            crashed += 1
            div.append('%s\tCRASH exit %s' % (label, oval))
            return
        if ours != theirs:
            verdict_diff += 1
            div.append('%s\t%s' % (label, 'tomllib accepts, tomlc rejects'
                                   if theirs else 'tomlc accepts, tomllib rejects'))
            return
        verdict_same += 1
        if not ours:
            return
        d = cmp_json(tval, oval)
        if d:
            value_diff += 1
            div.append('%s\tvalue: %s' % (label, d))
        else:
            value_same += 1

    for name in valid + invalid:
        path = os.path.join(corpus, name)
        with open(path, 'rb') as f:
            one(name, path, f.read())
    for text, label in EDGES:
        data = text.encode('utf-8', 'surrogateescape') \
            if not isinstance(text, bytes) else text
        with open(tmp, 'wb') as f:
            f.write(data)
        one('edge/' + label.replace(' ', '-'), tmp, data)
    for label, text in gen_docs(120):
        data = text.encode('utf-8')
        with open(tmp, 'wb') as f:
            f.write(data)
        one(label, tmp, data)

    print('DIFF verdict agreement with tomllib: %d/%d'
          % (verdict_same, verdict_same + verdict_diff))
    print('DIFF value agreement with tomllib: %d/%d'
          % (value_same, value_same + value_diff))
    # Printed unconditionally, including the zero. A crash count that only
    # appears when it is non-zero is a line nobody learns to look for, and
    # the denominators above do not include crashes -- so without this the
    # reader cannot tell 906 comparisons from 906 comparisons plus some
    # number of aborts.
    print('DIFF documents that crashed rather than parsing or rejecting: %d'
          % crashed)
    for d in sorted(div):
        print('DIVERGENCE %s' % d)
    if pin:
        with open(pin, 'w') as f:
            f.write('\n'.join(sorted(div)) + ('\n' if div else ''))
    return 1 if crashed else 0


def main():
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    mode, tomlc, corpus = sys.argv[1], sys.argv[2], sys.argv[3]
    pin = None
    if '--pin' in sys.argv:
        pin = sys.argv[sys.argv.index('--pin') + 1]
    if mode == 'suite':
        sys.exit(suite(tomlc, corpus, pin))
    if mode == 'tomllib':
        sys.exit(tomllib_mode(tomlc, corpus, pin))
    sys.exit('unknown mode %s' % mode)


if __name__ == '__main__':
    main()
