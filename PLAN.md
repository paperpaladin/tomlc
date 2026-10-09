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

- [x] `the lexer: whitespace, comments, newlines, UTF-8, CLI skeleton`
      why: an accept/reject harness has to exist before anything can be scored
      against it, and a document of nothing but blank lines and comments pins
      the framing: two whitespace bytes, two newline forms, no control
      character in a comment.
      watched failing: the plain c < 0x20 comment test, 26 passed 1 failed.
- [x] `bare keys and booleans: the first key = value line`
      why: the statement framing and the duplicate-key rule, which has to land
      with the table it applies to rather than later.
      watched failing: the duplicate check stubbed to if (0), 1 failure.
- [x] `basic strings: the closed escape set, control characters, quoted keys`
      why: strings are where a corpus concentrates its failures, and a lone
      surrogate escape has no UTF-8 encoding, so rejecting it is what keeps
      the dumper total.
      watched failing: the surrogate half of the scalar-value check, 3.
- [x] `literal strings and the two multi-line forms`
      why: the quote run (n<3 content, 3 close, 4-5 content-then-close) and
      the line-ending backslash are the two things every parser gets wrong
      once.
      watched failing: the quote-run limit raised from 5 to 8, 2 failures.
- [x] `integers: four bases, underscores, and the 64-bit boundary`
      why: scanning the whole token and then validating it is what makes
      "42 the ultimate answer?" and 0xaafz errors at the number.
      watched failing: half the range check, 4 failures.
- [x] `floats: the grammar by hand, inf and nan`
      why: strtod accepts 0x10, inf, nan, a leading plus and leading
      whitespace, and on "1e" consumes just the 1 and reports success, so it
      cannot be the validator.
      watched failing: an empty fractional part allowed, 4 failures.
- [x] `the four date-time types`
      why: toml-test compares the type as well as the value, so a parser that
      calls 07:32:00 a datetime scores zero on that file.
      watched failing: days_in_month flattened to 31, 3 failures.
- [x] `table headers and the current-table structure`
      why: the implicit/explicit distinction is the whole of TOML's table
      model and nothing after this works without it.
      watched failing: a header allowed to claim any table, 3 failures.
- [x] `dotted keys`
      why: "may extend a table it created itself, in the same body" needs the
      epoch; a boolean flag is wrong for [a.b.c] then [a] b.c.t, and
      "closed after this line" is wrong for b.c then b.d.
      watched failing: the dotted-and-same-epoch test, 3 failures.
- [x] `inline tables`
      why: first recursive production, so the depth guard lands here.  The
      newline rule falls out of using skip_ws and never skip_blank.
      watched failing: the comma branch accepting '}', 2 failures.  Note that
      deleting the trailing-comma check fails nothing, which is worth knowing.
- [x] `arrays`
      why: the mirror image -- newlines and comments everywhere, trailing
      comma allowed.  Using one whitespace helper for both is the bug.
      watched failing: separators treated as optional, 3 failures.
- [x] `arrays of tables`
      why: a statically defined array is a value and [[a]] must not append to
      it, and a path step through an array lands in its *last* element.
      watched failing: the F_AOT test dropped, 1 failure.
- [x] `the redefinition rules`
      why: two thirds of toml-test's invalid/ tree is this one subject, and
      passing *through* a closed table is as much an extension as landing on
      it -- the case a parser written around "is the final key taken?" misses.
      watched failing: the F_INLINE and F_DOTTED descend tests, 3 failures.
- [x] `the JSON dumper in toml-test's tagged encoding`
      why: this is what makes conformance a JSON diff with no judgement in it,
      and the first commit whose tests look at the value rather than the
      verdict.  It immediately proved the multi-line trimming rules that no
      accept/reject test could see.
      watched failing: the blank-line loop deleted from the line-ending
      backslash, 2 failures.
- [x] `the toml-test oracle: 208/208 valid, 501/501 invalid`
      why: this is the project.  Everything before it was unverified.
      found: the redefinition rules were too strict (206/208 on the first
      run); two of this repository's own tests asserted the wrong thing.
      watched failing: three ways, including hiding the vendored tarball,
      which reports "not ok" rather than skipping silently.
- [x] `the tomllib differential oracle: 900/906, 282/284, 8 pinned`
      why: a second conforming implementation by other people, over the
      corpus plus a named edge battery plus generated and mutated documents.
      found: tomllib rejects leap seconds, which TOML 1.0.0 allows.  A real
      non-conformance in the Python standard library.
      found in the harness: the edge battery was unpacked (label, document)
      instead of (document, label), so it wrote the labels to disk and
      reported 906/906 with zero divergences.  A suite silently doing
      nothing, caught only because the result was too good.
- [x] `the truncation sweep, and the two over-allocations that hid it`
      why: every prefix of every corpus file is 45517 malformed documents we
      did not have to invent.
      found: slurp over-allocated and the sweep reused the full buffer, so
      AddressSanitizer came back clean on a real off-by-one.  Both fixed and
      both verified by reintroducing the bug.
- [x] `README, PLAN and the error-message format`
      why: a README that only lists successes is not finished, and a format
      the README documents should be asserted rather than described.

Next, in order:

- [ ] `score the 1.1 file list as a second, separate number`
      why: the suite ships tests/files-toml-1.1.0 and we deliberately fail
      parts of it.  Printing "1.1: N/M, and here is exactly which files and
      why" is a stronger statement than "1.1 not supported", and it would
      make the eventual decision about 1.1 a measurement rather than an
      argument.  Needs the runner to take the list as a parameter and a
      second pinned expectation file; the code does not change.
- [ ] `a real arena behind the node registry`
      why: one malloc per node and one per string.  The registry already
      makes freeing a single loop, so the remaining win is allocation count,
      and nothing here is currently allocation-bound -- `-S` over the corpus
      is 45517 parses in under a second.  Measure before writing it.
- [ ] `locale independence, or stop using strtod`
      why: the one limitation in the README asserted from the standard rather
      than demonstrated, because no comma-decimal locale is installed.
      Either install one and add the test, or convert the decimal digits
      directly and remove the last thing that can surprise a caller who has
      called setlocale.
- [ ] `coverage-guided fuzzing`
      why: the truncation sweep and 60 byte-mutations are the cheap version.
      afl is not installed and libFuzzer is clang-only, so this needs a
      decision about what may be installed before it needs code.
- [ ] `an API, or a documented refusal`
      why: every function is static and there is no header.  Half an API is
      something someone files a bug about; "no, it is a CLI" in the README is
      a cheaper answer than exporting a tree type we would then have to keep
      stable.
