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

# --- bare keys and booleans ------------------------------------------------
printf '\n--- bare keys, booleans\n'
acc 'a = true'                'bare key, true'
acc 'a = false\n'             'bare key, false'
acc 'A-Z_az-09 = true'        'every character legal in a bare key'
acc '1234 = true'             'all-digit bare key'
acc '-_- = true'              'bare key of only dashes and underscores'
acc 'a=true'                  'no space around ='
acc 'a   =   true   '         'whitespace around = and after the value'
acc 'a = true # c'            'comment after a value'
acc 'a = true\nb = false\n'   'two key/value lines'
acc 'a = true\r\nb = false\r\n' 'two key/value lines, CRLF'
acc '# c\n\na = true\n\n# c\n' 'comments and blank lines around a pair'
rej 'a = true b = false'      'two pairs on one line'
rej 'a = True'                'capitalised True'
rej 'a = TRUE'                'uppercase TRUE'
rej 'a = truee'               'true with a trailing letter'
rej 'a = tru'                 'truncated true'
rej 'a ='                     'key with no value'
rej 'a = \n'                  'value on the next line'
rej 'a'                       'key with no equals'
rej 'a true'                  'missing equals'
rej 'a == true'               'double equals'
rej 'a = = true'              'equals twice with a space'
rej '= true'                  'no key'
rej 'a b = true'              'space inside a bare key'
rej 'a\tb = true'             'tab inside a bare key'
rej 'a! = true'               'invalid character in a bare key'
rej '! = true'                'bare key that is only punctuation'
rej 'a# = true'               'hash inside a bare key'
rej '\302\265 = true'          'non-ASCII bare key (U+00B5)'
rej 'a = true\ra = false'      'bare CR between two pairs'
rej 'a = true\nb'             'trailing key with no value'
rej 'a = true\na = false'      'duplicate key'
rej 'a\n  = true'             'newline between key and equals'

pass=$(grep -c '^ok - ' "$OUT")
fail=$(grep -c '^not ok - ' "$OUT")
printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
