# tomlc

A TOML 1.0.0 parser in one C11 file, plus a CLI that validates with its exit
status and dumps the parsed document as JSON.  No dependencies beyond libc.
1379 lines including the comments.

```sh
make            # gcc -std=c11 -Wall -Wextra -Wpedantic -O2
make test       # 630 checks, including the conformance score
make test-asan  # the same, under -fsanitize=address,undefined
```

```sh
tomlc FILE          # exit 0 valid, exit 1 invalid, message on stderr
tomlc -j FILE       # dump the document as toml-test tagged JSON
tomlc -S FILE       # parse every truncation of FILE; report only that none crashed
tomlc -h            # usage
```

## The score, which is the only interesting claim

Anyone can write a TOML parser and assert that it is conformant.  The claim is
unverifiable without numbers from a corpus the author did not write, so here
they are, from [toml-test](https://github.com/toml-lang/toml-test) (MIT, the
TOML authors), the standard cross-implementation suite:

```
SCORE valid accepted with the expected value: 208/208
SCORE invalid rejected: 501/501
```

**No failures, nothing skipped, nothing excluded by us.**  The valid score is
not just "did it parse": each `valid/*.toml` ships a `valid/*.json` giving the
exact expected parse, and all 208 are compared value by value.  That is what
the tagged encoding is for -- `{"type": "integer", "value": "42"}` makes the
comparison a JSON diff with no judgement in it.

### What exactly is vendored, and why that subset

`t/toml-test-1.0.0.tar.gz` (48KB, sha256
`f834ef8c87da6dfc8ad78bf145532aa38dd103971ce8c7585d0692aa1577b4bc`), fetched
from the suite's `main` branch on 2026-10-09 (upstream's last tagged release
at that point was v2.2.0, 2026-03-30).  Licence beside it in
`t/toml-test-LICENSE`.  It holds 918 files: the 208 valid `.toml` documents,
their 208 expected `.json` files, the 501 invalid `.toml` documents, and the
suite's own `tests/files-toml-1.0.0` list.

That list is upstream's, not ours.  toml-test ships separate file lists for
TOML 1.0.0 and 1.1.0 because several documents are valid in one version and
invalid in the other, and `version.go` is where upstream decides which.  Using
their 1.0.0 list means the denominator is their choice; picking files
ourselves would make the score meaningless.  The files 1.0.0 excludes are
exactly the places where TOML 1.1 changed the language:

| excluded by upstream from 1.0.0 | why |
| --- | --- |
| `valid/string/escape-esc`, `valid/string/hex-escape` | `\e` and `\x41` are 1.1 escapes |
| `valid/datetime/no-seconds` | seconds became optional in 1.1 |
| `valid/inline-table/newline`, `-comment` | newlines in inline tables are 1.1 |
| `valid/key/empty-05` | 1.1 key rules |
| `invalid/control/multi-cr`, `rawmulti-cr` | upstream issue #174, a bare CR in a multi-line string is unsettled |
| `valid/spec-1.1.0/*`, `invalid/spec-1.1.0/*` | the 1.1 spec examples |

Not vendored: the suite's Go runner, its `parsers/` tree, its 1.1 file list,
and the 1.1-only test files.  We score against 1.0.0 and only 1.0.0.

### The harness counts a crash as a failure

Any exit status outside `{0, 1}` is a failure regardless of what the filename
asks for.  A segfault satisfies "did not exit 0", so a harness written as
`! ./tomlc "$f"` scores a crash as a pass on every `invalid/` file.  Ours does
not, and the per-file verdicts for all 709 files are pinned in
`t/suite.expected` and diffed on every run, so a change that keeps the totals
but moves a file still fails.

That held for the corpus scoring and **not** for the tomllib differential.
`our_parse` returned the same `(False, None)` for exit 1 and for exit 139, so
a crash on an invalid document was indistinguishable from a clean rejection:
tomllib rejects it too, the verdicts agree, and the crash is counted as
agreement.  It was the only code path that sees the 17 edge documents and the
180 generated ones, 60 of them byte-mutated -- the only inputs here nobody
chose.

Measured, with `tomlc` calling `abort()` where it returns 1 -- so every
document it would have rejected now crashes instead:

```
old:  899/906 agreement, 0 crashes reported
new:  284/287 agreement, 619 crashes reported
```

619 documents crashed, and the old two-outcome code counted **615 of them as
agreement**: `(False, None)` said we had rejected what we had in fact aborted
on, and the old run's numbers are byte-identical to a clean one. `our_parse`
now has a third outcome, the count is printed unconditionally including the
zero, and `t/run.sh` asserts it.

(These figures were 638/906, 438/442, 464 crashes and "200 as agreement".
None of them reproduce: 464 is also arithmetically impossible now, since
tomlc rejects 619 of the 906 documents and 501 of those are the invalid
corpus alone.)

### The first real bug the suite found

On the first run the score was 206/208.  The redefinition rules, written two
commits earlier from the spec prose, rejected a header that passes *through* a
table created by a dotted key.  But `valid/spec-1.0.0/table-9.toml` is

```toml
[fruit]
apple.color = "red"
apple.taste.sweet = true

[fruit.apple.texture]  # you can add sub-tables
smooth = true
```

A header may add a new sub-table to a dotted-key table; what it may not do is
land on one.  Two of this repository's own hand-written tests asserted the
wrong thing and had to be corrected -- the hand-written tests agreed with the
bug, which is the entire argument for an oracle somebody else wrote.

## Second oracle: Python's `tomllib`

A second conforming TOML 1.0.0 implementation, by other people, in another
language, run over the same 709 corpus files plus seventeen named edge
documents and 180 generated ones (120 built from a grammar with a fixed seed,
60 of those then mutated by a flipped, inserted or deleted byte):

```
DIFF verdict agreement with tomllib: 899/906
DIFF value agreement with tomllib: 282/284
```

Nine divergences, all pinned in `t/py_divergences.expected`, each one checked
against the spec text rather than assumed to be in our favour:

| divergence | who is right |
| --- | --- |
| `23:59:60` and `1990-12-31T23:59:60Z` -- we accept, tomllib rejects | **we are.**  The 1.0.0 ABNF reads `time-second = 2DIGIT ; 00-58, 00-59, 00-60 based on leap second rules`, and toml-test's own over-range case uses `61` and quotes that line.  tomllib's `_TIME_RE_STR` spells seconds `([0-5][0-9])`, so 60 cannot match; `datetime.time` has no representation for a leap second, so this is forced on it.  The only divergence here that is a defect rather than a choice. |
| `9223372036854775808`, `-9223372036854775809`, `0xffffffffffffffff` -- tomllib accepts, we reject | **both.**  The spec ties this to representation, not to a fixed range: "if an integer cannot be represented losslessly, an error must be thrown".  Python's `int` can represent them; our `int64_t` cannot.  toml-test has no integer-overflow file at all, which is what you would expect of a question with no single answer. |
| `00:32:00.9999999` and twelve fractional digits -- same verdict, different value | **both.**  tomllib truncates to microseconds (`datetime` again), we keep every digit written.  The spec: "if the value contains greater precision than the implementation can support, the additional precision must be truncated, not rounded."  toml-test's comparator truncates both sides to nanoseconds anyway. |
| 300 nested arrays -- tomllib accepts, we reject | **both.**  Our depth limit is 200 (see below).  The spec says nothing about depth. |
| a leading UTF-8 BOM -- we accept, tomllib rejects | **we are.**  toml-test ships `invalid/encoding/bom-not-at-start-01..03` and no `bom-at-start` case, so the suite's own position is that a BOM at the start is acceptable and only a BOM elsewhere is not.  tomllib decodes first, so the BOM arrives as U+FEFF where a bare key is expected; its documentation puts the responsibility for stripping it on the caller. |

Three cases where we accept something tomllib rejects: the two leap seconds
and a leading BOM. That is the direction that would be alarming, so each one
is argued above rather than listed.

The BOM case was not visible until recently. It was written as a Python `str`
of five characters, which encodes to six bytes of mojibake -- both parsers
reject that as a bad key, so it scored as agreement and tested nothing about
BOMs at all. With the real three bytes the disagreement appears, and verdict
agreement is 899/906 rather than 900/906.

## Third oracle: the sanitizers

`make test-asan` builds with `-fsanitize=address,undefined`,
`detect_leaks=1`, `halt_on_error=1` and runs the whole suite, including the
truncation sweep: **45517** malformed documents, every prefix of every corpus
file, plus ten hand-written cut shapes the corpus does not contain (an escape
cut in half, a multi-line delimiter cut between its quotes, a date-time cut at
every field boundary, an inline table cut mid-key) and 400kB of
`/dev/urandom`.  Clean: 630 passed, 0 failed.

Two allocation details decide whether any of that is worth running, and both
were wrong first:

- `slurp` read into a doubling buffer and left it over-allocated, so a read
  one byte past the end of the document landed inside the allocation and came
  back clean.  It now shrinks to exactly `n`.
- the sweep passed that same full-size buffer with a shorter length, which has
  the identical effect for every prefix.  It now copies each prefix into a
  fresh allocation of exactly that many bytes.

Verified rather than assumed: with the truncation check removed from
`utf8_bad`, `make test-asan` reports `heap-buffer-overflow tomlc.c:137 in
utf8_bad` and the truncation sweep goes red -- 33 of the 709 corpus files trip
it, the first being `invalid/encoding/bad-codepoint.toml`, not the first file
in the sweep.  With the over-allocations restored and the same bug in place,
it does not.

The build is bit-for-bit reproducible across build directory, `TZ`, locale,
umask, `-j` and `SOURCE_DATE_EPOCH`
(`python3 unrepro/unrepro.py check . --cmd 'make -B'`: REPRODUCIBLE).

## What does NOT work

This is the honest half.

**No TOML 1.1.**  Deliberately.  `\e` and `\x41` escapes, times without
seconds (`17:45`), newlines inside inline tables, and unicode bare keys
(a bare key spelled with U+00B5 MICRO SIGN) are all errors here.  Several of them are in toml-test's
`invalid/` tree *for 1.0.0*, so accepting them would turn the 501/501 into a
lie.  There is no flag to switch versions.

**No encoder.**  Nothing writes TOML.  The JSON dumper exists to be diffed
against the corpus; it is not a general serialiser and it has no options, no
indentation and no sorting -- keys come out in document order.

**No API.**  It is one `.c` file with a `main`, not a library.  There is no
header, no `toml_get`, no way to mutate a parsed tree, and every function is
`static`.  `#include "tomlc.c"` would work and is not supported.

**Integers are `int64_t` and overflow is a parse error.**  `2**63` is rejected
rather than promoted to a float or saturated.  Conforming, and a divergence
from tomllib (above), but if your document has a 2**64 bitmask in it this
parser will not read it.

**Floats are `double` and overflow is silent.**  `1e400` parses to `inf` and
nothing in the output says precision or magnitude was lost.  `0.1` is the
nearest double to 0.1, not 0.1.  This is permitted and it is still a
surprise.

**Depth is capped at 200.**  201 nested arrays or inline tables is
`nesting too deep` and exit 1.  Nothing real nests that deep, but a
machine-generated document might, and the limit is a compile-time constant
with no flag.

**At most 64 dotted parts in one key.**  `a.b.c....` deeper than 64 is a parse
error, not a deeper key.  Marked `shortcut:` in the source.

**Date-times are text, not time.**  They are validated (calendar-correct,
leap-year-correct, range-checked, leap second allowed) and then kept as the
normalised source string.  There is no conversion to `time_t`, no timezone
database, no arithmetic, and no normalisation of an offset to UTC: `-00:00`
stays `-00:00`.  Fractional seconds are kept verbatim at any length, so a
caller that wants nanoseconds has to truncate them itself.

**CRLF inside a multi-line string becomes LF.**  TOML 1.0.0 lets a parser
"normalize newline to whatever makes sense"; we normalise, like tomllib.  No
valid toml-test case can tell the difference, so this choice is pinned by
nothing but this paragraph.  A bare CR inside a multi-line string is rejected,
which upstream issue #174 says is unsettled -- the two corpus files for it are
excluded from the 1.0.0 list, so they do not score either way.

**A leading UTF-8 BOM is skipped.**  TOML 1.0.0 says nothing about a BOM.  A
second BOM is an error.  The corpus's BOM cases are in the 1.1 list only, so
this too is pinned by nothing but this paragraph.

**Comments and formatting are discarded.**  Parse, dump, and you have lost
every comment, the original spelling of every number (`0x10` dumps as `16`),
and the distinction between `[a]` and `a = {}`.

**DEL (U+007F) is rejected in comments.**  The 1.0.0 ABNF's
`non-eol = %x09 / %x20-7F` permits it; the spec prose ("control characters
other than tab are not permitted in comments") does not; toml-test rejects it.
We follow the prose and the corpus, which means we are stricter than the
grammar as literally written.

**Locale.**  `strtod` is used for the float value only, after the text has
been validated by hand and the underscores stripped, so it never acts as the
validator.  But it is locale-dependent, and a C program starts in the `"C"`
locale only until something calls `setlocale`.  The CLI never does, so the CLI
is safe; a caller that pasted this file into a program with
`setlocale(LC_NUMERIC, "de_DE")` would silently read `3.14` as `3`.  Not
tested, because no comma-decimal locale is installed on this machine --
`locale -a` lists none -- so this limitation is asserted from the standard
rather than demonstrated, which is weaker and is why it is written down here.

**Not fuzzed.**  The truncation sweep plus 400kB of `/dev/urandom` plus 60
single-byte mutations is the cheap version.  There is no coverage-guided
fuzzing: `afl` is not installed and libFuzzer needs clang-only flags.

## Layout

```
tomlc.c                      the parser, the dumper and the CLI
Makefile                     all / test / test-asan / clean
t/run.sh                     every check; prints the score and "N passed, M failed"
t/oracle.py                  the two oracles: `suite` and `tomllib`
t/toml-test-1.0.0.tar.gz     the vendored corpus subset
t/toml-test-LICENSE          its MIT licence
t/suite.expected             the 709 pinned per-file verdicts
t/py_divergences.expected    the 8 pinned tomllib divergences
```

GPL-3.0-or-later; see `LICENSE`.  The vendored corpus is MIT and keeps its own
licence beside it.
