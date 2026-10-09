# PLAN

## Contract

`tomlc` is one C11 file that parses a TOML 1.0.0 document into a tree and a CLI
that scores itself against a corpus it did not write.

- `tomlc FILE` validates: exit 0 valid, exit 1 invalid with one
  `file:line:col: message (byte N)` on stderr.  Any other exit status is a bug,
  and the test harness treats it as one.
- `tomlc -j FILE` dumps the parsed document in toml-test's tagged JSON
  encoding, where every scalar is `{"type": ..., "value": ...}` and every value
  is a string.  That encoding is the whole reason the project is testable: the
  comparison against the corpus is a JSON diff with no judgement in it.
- `tomlc -S FILE` runs the truncation sweep: parse every prefix of the file and
  report only that nothing crashed.
- Everything TOML 1.0.0 has: tables, inline tables, arrays, arrays of tables,
  the four string forms, integers in four bases, floats including `inf` and
  `nan`, booleans, and the four date-time types.
- Not in the contract: serialising back to TOML, mutating a parsed document,
  preserving comments or key order for round-tripping, TOML 1.1 (seconds-
  optional times, `\x` escapes, newlines in inline tables, unicode bare keys),
  or any locale other than C.

## Hard invariant

**Acceptance is exactly the TOML 1.0.0 grammar, the parsed value is exactly
what toml-test says it is, and no input can crash, hang, read out of bounds or
leak.**

All three halves are externally checked.  The first two are scored against
toml-test, which supplies both the accept/reject verdict and the expected
parse; the third is checked by parsing every truncation of every corpus file
under `-fsanitize=address,undefined`.

A TOML parser that claims conformance without a number from a corpus the author
did not write is making an unverifiable claim.  The number is the deliverable.

## Oracle

Ranked by how little we control them.

1. **toml-test** (github.com/toml-lang/toml-test, MIT, TOML authors).  The
   standard cross-implementation suite.  `tests/valid/` pairs each `.toml` with
   a `.json` giving the exact expected parse; `tests/invalid/` must all be
   rejected.  `tests/files-toml-1.0.0` names the subset that applies to TOML
   1.0.0, which is the version we implement, so that list is the vendored
   subset: 208 valid documents with their expected JSON and 501 invalid ones.
   Not ours, not derived from our reading of the spec, and built specifically
   out of the inputs that broke real parsers -- two thirds of `invalid/` is
   about the redefinition rules alone.
2. **Python's `tomllib`** (3.11+, standard library, a conforming TOML 1.0.0
   parser by other authors).  A differential oracle in two directions:
   accept/reject agreement over the whole corpus, and value agreement -- parse
   with both, project both into the same tagged encoding, compare.  Plus
   generated documents, which is the only part of the testing that is not
   limited to inputs somebody already thought of.
3. **The sanitizers.**  `-fsanitize=address,undefined` over the truncation
   sweep: every prefix of every corpus file is a malformed document we did not
   have to invent.  Not a correctness oracle, but the only authority on memory
   safety that is not our own opinion.

## Non-goals

- TOML 1.1.  The suite ships a 1.1 file list as well; we score against the
  1.0.0 list and say so.  Accepting 1.1 syntax would make the 1.0.0 score a
  lie, since several 1.1-valid documents are in `invalid/` for 1.0.0.
- An encoder.  There is no `toml_write`.  The JSON dumper exists to be diffed
  against the corpus, not to be a serialisation API.
- Preserving the spelling of a number.  `0x10`, `16` and `1_6` all parse to the
  integer 16 and dump as `"16"`, which is what toml-test expects.
- Arbitrary-precision integers or decimal floats.  Integers are `int64_t` and
  out-of-range is a parse error, as the spec requires; floats are `double`.
- A streaming or incremental interface.  The document is in memory anyway.

## Commit sequence

- [ ] `the lexer: whitespace, comments, newlines, UTF-8, CLI skeleton`
- [ ] `bare and quoted keys, and booleans as the first value type`
- [ ] `basic strings: the escape set, control characters, \u`
- [ ] `literal strings and the two multi-line forms`
- [ ] `integers: four bases, underscores, and the 64-bit boundary`
- [ ] `floats: the grammar by hand, inf and nan`
- [ ] `the four date-time types`
- [ ] `table headers and the current-table structure`
- [ ] `dotted keys`
- [ ] `inline tables`
- [ ] `arrays`
- [ ] `arrays of tables`
- [ ] `the redefinition rules`
- [ ] `the JSON dumper in toml-test's tagged encoding`
- [ ] `the toml-test oracle: the score, pinned`
- [ ] `the tomllib differential oracle`
- [ ] `the truncation sweep`
- [ ] `README and PLAN`
