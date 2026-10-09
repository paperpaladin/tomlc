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

# --- basic strings and quoted keys -----------------------------------------
# Case text goes through printf '%b', so a backslash in the TOML is doubled
# here and \NNN injects a raw byte.
printf '\n--- basic strings\n'
acc 'a = ""'                       'empty basic string'
acc 'a = "x"'                       'one-character string'
acc 'a = "hello world"'             'string with spaces'
acc 'a = "\\b\\t\\n\\f\\r"'            'the five single-letter escapes'
acc 'a = "\\""'                      'escaped quote'
acc 'a = "\\\\"'                      'escaped backslash'
acc 'a = "\\u0041"'                  'four-digit unicode escape'
acc 'a = "\\u0000"'                  'escaped NUL inside a string'
acc 'a = "\\uffff"'                  'lowercase hex in an escape'
acc 'a = "\\uFFFF"'                  'uppercase hex in an escape'
acc 'a = "\\U0001F600"'              'eight-digit unicode escape'
acc 'a = "\\U0010FFFF"'              'highest scalar value'
acc 'a = "a\\tb"'                    'escaped tab'
acc 'a = "a\011b"'                  'raw tab is legal in a basic string'
acc 'a = "\302\242\343\201\202\360\237\230\200"' 'raw UTF-8 of two, three and four bytes'
acc 'a = "#"'                       'hash inside a string is not a comment'
acc 'a = "x" # c'                    'comment after a string'
acc '"a" = "b"'                      'quoted key'
acc '"" = "x"'                       'empty quoted key'
acc '"127.0.0.1" = "x"'              'quoted key with dots inside it'
acc '"\\u0041" = "x"'                 'escape inside a quoted key'
rej 'a = "'                          'lone quote'
rej 'a = "abc'                       'unterminated string'
rej 'a = "abc\n'                     'string broken by a newline'
rej 'a = "abc\r\nb = 1"'             'string broken by a CRLF'
rej 'a = "\\"'                        'string ending in a dangling escape'
rej 'a = "\\x41"'                     'hex escape \\x'
rej 'a = "\\e"'                       'escape \\e'
rej 'a = "\\'"'"'"'                   'escaped single quote'
rej 'a = "\\/"'                       'escaped solidus'
rej 'a = "\\ "'                       'escaped space'
rej 'a = "\\u00"'                     'short \\u escape'
rej 'a = "\\u00G0"'                   'non-hex digit in \\u'
rej 'a = "\\u 000"'                   'space inside \\u'
rej 'a = "\\uD800"'                   'lone high surrogate escape'
rej 'a = "\\uDFFF"'                   'lone low surrogate escape'
rej 'a = "\\uD800\\uDC00"'             'surrogate pair escapes (not TOML)'
rej 'a = "\\U00110000"'               'escape above U+10FFFF'
rej 'a = "\\UFFFFFFFF"'               'escape with every bit set'
rej 'a = "x\000y"'                   'raw NUL inside a string'
rej 'a = "x\001y"'                   'raw SOH inside a string'
rej 'a = "x\010y"'                   'raw backspace inside a string'
rej 'a = "x\015y"'                   'raw CR inside a string'
rej 'a = "x\037y"'                   'raw 0x1F inside a string'
rej 'a = "x\177y"'                   'raw DEL inside a string'
rej '"a = 1'                         'unterminated quoted key'
rej '"a\nb" = 1'                     'newline inside a quoted key'
rej 'a"b" = 1'                       'bare key glued to a quoted key'
rej '"a" "b" = 1'                    'two quoted keys'
rej '"a"\t"b" = 1'                   'two quoted keys separated by a tab'

# --- literal strings and the two multi-line forms --------------------------
printf '\n--- literal and multi-line strings\n'
acc "a = ''"                        'empty literal string'
acc "a = 'C:\\\\Users'"               'backslash is literal in a literal string'
acc 'a = '"'"'he said "hi"'"'"''    'double quotes inside a literal string'
acc "a = '\\\\u0041'"                 'no escape processing in a literal string'
acc "a = 'x\011y'"                  'raw tab in a literal string'
acc "'a' = 'b'"                     'literal-string key'
rej "a = 'x"                        'unterminated literal string'
rej "a = 'x\ny'"                    'newline in a literal string'
rej "a = 'x\015y'"                  'raw CR in a literal string'
rej "a = 'x\000y'"                  'raw NUL in a literal string'
rej "a = 'x\177y'"                  'raw DEL in a literal string'
rej "a = 'x\001y'"                  'control character in a literal string'

acc 'a = """"""'                     'empty multi-line basic string'
acc 'a = """x"""'                    'one line in a multi-line basic string'
acc 'a = """\nx\ny"""'               'newline trimmed after the opening delimiter'
acc 'a = """\r\nx\r\ny"""'           'CRLF trimmed after the opening delimiter'
acc 'a = """x\\\n   y"""'             'line-ending backslash'
acc 'a = """x\\   \n\n\n   y"""'      'line-ending backslash with trailing spaces and blank lines'
acc 'a = """x\\\r\n   y"""'           'line-ending backslash before CRLF'
acc 'a = """x\\\n"""'                 'line-ending backslash before the closing delimiter'
acc 'a = """"x"""'                   'one quote right after the opening delimiter'
acc 'a = """x""""'                   'string ending in one quote'
acc 'a = """x"""""'                  'string ending in two quotes'
acc 'a = """x""y"""'                 'two quotes inside a multi-line string'
acc 'a = """\\u0041\\t"""'             'escapes inside a multi-line string'
acc 'a = """x\011y"""'               'raw tab inside a multi-line string'
rej 'a = """'                        'unterminated multi-line basic string'
rej 'a = """x""'                     'multi-line string closed with two quotes'
rej 'a = """x""""""'                 'three quotes of content'
rej 'a = """x\\q"""'                  'unknown escape in a multi-line string'
rej 'a = """x\\ y"""'                 'backslash that is not last on the line'
rej 'a = """x\015y"""'               'bare CR inside a multi-line string'
rej 'a = """x\000y"""'               'NUL inside a multi-line string'
rej 'a = """x\177y"""'               'DEL inside a multi-line string'
rej 'a = """x\001y"""'               'control character inside a multi-line string'

acc "a = ''''''"                     'empty multi-line literal string'
acc "a = '''x'''"                    'one line in a multi-line literal string'
acc "a = '''\nx\ny'''"               'newline trimmed after the opening delimiter'
acc "a = '''x\\\\ny'''"               'backslash is literal in a multi-line literal string'
acc "a = ''''x'''"                   'one quote right after the opening delimiter'
acc "a = '''x''''"                   'string ending in one quote'
acc "a = '''x'''''"                  'string ending in two quotes'
acc "a = '''x''y'''"                 'two quotes inside a multi-line literal string'
rej "a = '''"                        'unterminated multi-line literal string'
rej "a = '''x''"                     'multi-line literal closed with two quotes'
rej "a = '''x''''''"                 'three quotes of content'
rej "a = '''x\015y'''"               'bare CR inside a multi-line literal string'
rej "a = '''x\000y'''"               'NUL inside a multi-line literal string'
rej "a = '''x\177y'''"               'DEL inside a multi-line literal string'

rej 'a = """x""" = 1'                'multi-line string used as a key'
rej '"""a""" = 1'                    'multi-line basic string as a key'
rej "'''a''' = 1"                    'multi-line literal string as a key'
rej '"""a\nb""" = 1'                 'multi-line key spanning lines'

# --- integers --------------------------------------------------------------
printf '\n--- integers\n'
acc 'a = 0'                    'zero'
acc 'a = +0'                   'plus zero'
acc 'a = -0'                   'minus zero'
acc 'a = 42'                   'a positive integer'
acc 'a = +42'                  'an explicitly positive integer'
acc 'a = -42'                  'a negative integer'
acc 'a = 1_000'                'underscores as digit separators'
acc 'a = 1_1_1_1'              'an underscore between every digit'
acc 'a = 9223372036854775807'  'int64 max'
acc 'a = -9223372036854775808' 'int64 min'
acc 'a = 0xDEADBEEF'           'hex, upper case digits'
acc 'a = 0xdead_beef'          'hex with an underscore'
acc 'a = 0x00987'              'leading zeros are legal in hex'
acc 'a = 0x7fffffffffffffff'   'int64 max in hex'
acc 'a = 0o755'                'octal'
acc 'a = 0o7_6_5'              'octal with underscores'
acc 'a = 0o00000'              'octal zeros'
acc 'a = 0b11010110'           'binary'
acc 'a = 0b1_0_1'              'binary with underscores'
acc 'a = 0b00000'              'binary zeros'
acc 'a = 0x0'                  'hex zero'
rej 'a = 01'                   'leading zero'
rej 'a = 00'                   'two zeros'
rej 'a = 0_0'                  'zero underscore zero'
rej 'a = -01'                  'negative with a leading zero'
rej 'a = +01'                  'positive with a leading zero'
rej 'a = +0_1'                 'positive, leading zero, underscore'
rej 'a = 9223372036854775808'  'int64 max plus one'
rej 'a = -9223372036854775809' 'int64 min minus one'
rej 'a = 99999999999999999999999999' 'far above int64'
rej 'a = -99999999999999999999999999' 'far below int64'
rej 'a = 0x8000000000000000'   'hex above int64 max'
rej 'a = 0xffffffffffffffff'   'all ones in hex does not fit a signed 64-bit integer'
rej 'a = 1__23'                'double underscore'
rej 'a = _123'                 'leading underscore'
rej 'a = 123_'                 'trailing underscore'
rej 'a = 0x1_'                 'trailing underscore in hex'
rej 'a = 0x_1'                 'underscore straight after 0x'
rej 'a = _0x1'                 'underscore before 0x'
rej 'a = 0b'                   'incomplete binary'
rej 'a = 0x'                   'incomplete hex'
rej 'a = 0o'                   'incomplete octal'
rej 'a = 0X1'                  'capital X prefix'
rej 'a = 0O1'                  'capital O prefix'
rej 'a = 0B1'                  'capital B prefix'
rej 'a = -0x1'                 'signed hex'
rej 'a = +0x1'                 'positive signed hex'
rej 'a = -0o1'                 'signed octal'
rej 'a = -0b1'                 'signed binary'
rej 'a = 0x-1'                 'minus inside hex'
rej 'a = 0b0012'               'digit 2 in binary'
rej 'a = 0o778'                'digit 8 in octal'
rej 'a = 0xaafz'               'z in hex'
rej 'a = 0xgabba00f1'          'g in hex'
rej 'a = ++99'                 'double plus'
rej 'a = --99'                 'double minus'
rej 'a = 42 the ultimate answer?' 'text after an integer'
rej 'a = 1\331\240'              'ARABIC-INDIC DIGIT ZERO after a digit'
rej 'a = 1\0131'                'vertical tab inside a number'

pass=$(grep -c '^ok - ' "$OUT")
fail=$(grep -c '^not ok - ' "$OUT")
printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
