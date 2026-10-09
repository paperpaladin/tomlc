#!/bin/sh
# t/run.sh -- build tomlc, run every oracle, print the toml-test score and
# "N passed, M failed".
# SPDX-License-Identifier: GPL-3.0-or-later
#
# POSIX sh.  This script, not the Makefile, compiles tomlc, so `make test-asan`
# is a CFLAGS override and nothing else.
set -u

cd "$(dirname "$0")/.." || exit 1

CC=${CC:-gcc}
CFLAGS=${CFLAGS:--std=c11 -Wall -Wextra -Wpedantic -O2 -g}
SCRATCH=./scratch
mkdir -p "$SCRATCH"
OUT=$SCRATCH/results.txt
: > "$OUT"

say()  { printf '%s\n' "$*" | tee -a "$OUT"; }
ok()   { say "ok - $*"; }
nok()  { say "not ok - $*"; }

printf '=== building (CC=%s)\n' "$CC"
# shellcheck disable=SC2086
$CC $CFLAGS -o ./tomlc tomlc.c -lm || nok "compile tomlc"

# acc/rej take a printf '%b' format so a test case can inject a raw byte as
# \NNN and a literal backslash as \\.
acc() {
	if printf '%b' "$1" | ./tomlc 2>/dev/null; then ok "accept $2"
	else nok "accept $2"; fi
}
rej() {
	printf '%b' "$1" | ./tomlc >/dev/null 2>&1
	st=$?
	if [ "$st" -eq 1 ]; then ok "reject $2"
	elif [ "$st" -eq 0 ]; then nok "reject $2 (accepted)"
	else nok "reject $2 (exit $st, not a clean rejection)"; fi
}

# --- the lexer: whitespace, comments, newlines, encoding -------------------
printf '\n--- lexer\n'
acc ''                        'empty document'
acc '\n'                      'one newline'
acc '\r\n'                    'one CRLF'
acc '   \t  '                 'whitespace only'
acc '# comment'               'comment without a newline'
acc '# comment\n'             'comment with a newline'
acc '#\n#\n\n#\n'             'several comment and blank lines'
acc '# comment\t with a tab'  'tab inside a comment'
rej '\r'                      'bare CR'
rej '\r\r\n'                  'bare CR before a CRLF'
rej '# c\rx'                  'bare CR inside a comment'
rej '# \000'                  'NUL inside a comment'
rej '# \001'                  'control character inside a comment'
rej '# \177'                  'DEL inside a comment'
rej '\013'                    'vertical tab is not whitespace'
rej '\014'                    'form feed is not whitespace'
rej '\343\200\200'            'U+3000 IDEOGRAPHIC SPACE is not whitespace'
rej 'x'                       'bare word with no key/value'
acc '\357\273\277'            'leading UTF-8 BOM alone'
acc '\357\273\277# c\n'       'leading UTF-8 BOM then a comment'
rej '\357\273\277\357\273\277' 'two BOMs'
rej '# \303'                  'truncated UTF-8 sequence in a comment'
rej '# \355\240\200'          'UTF-8-encoded surrogate U+D800'
rej '# \300\257'              'overlong encoding of /'
rej '# \364\220\200\200'      'codepoint above U+10FFFF'
rej '# \200'                  'lone continuation byte'
rej '\000'                    'NUL byte alone'

pass=$(grep -c '^ok - ' "$OUT")
fail=$(grep -c '^not ok - ' "$OUT")
printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
