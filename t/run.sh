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

# --- floats ----------------------------------------------------------------
printf '\n--- floats\n'
acc 'a = 3.14'                 'a float'
acc 'a = +3.14'                'a signed float'
acc 'a = -3.14'                'a negative float'
acc 'a = 0.0'                  'zero point zero'
acc 'a = +0.0'                 'plus zero point zero'
acc 'a = -0.0'                 'minus zero point zero'
acc 'a = 0.123'                'zero integer part'
acc 'a = 0.0123'              'leading zero in the fractional part'
acc 'a = 3e2'                  'exponent without a fraction'
acc 'a = 3E2'                  'capital E exponent'
acc 'a = 3e+2'                 'signed exponent'
acc 'a = 3e-2'                 'negative exponent'
acc 'a = 0e0'                  'zero exponent'
acc 'a = 0e00'                 'leading zero in the exponent'
acc 'a = 3.1e2'                'fraction and exponent'
acc 'a = 3_141.5927'           'underscore in the integer part'
acc 'a = 3141.592_7'           'underscore in the fractional part'
acc 'a = 3e1_4'                'underscore in the exponent'
acc 'a = 3.141592653589793'    'a long float'
acc 'a = 1e400'                'exponent overflow becomes inf'
acc 'a = 1e-400'               'exponent underflow becomes zero'
acc 'a = inf'                  'inf'
acc 'a = +inf'                 'plus inf'
acc 'a = -inf'                 'minus inf'
acc 'a = nan'                  'nan'
acc 'a = +nan'                 'plus nan'
acc 'a = -nan'                 'minus nan'
rej 'a = .12345'               'leading dot'
rej 'a = -.12345'              'signed leading dot'
rej 'a = 1.'                   'trailing dot'
rej 'a = -1.'                  'signed trailing dot'
rej 'a = 0..1'                 'double dot'
rej 'a = 0.1.2'                'two dots'
rej 'a = 1.e2'                 'dot straight before the exponent'
rej 'a = 3.e+20'               'dot before a signed exponent'
rej 'a = 1e2.3'                'dot inside the exponent'
rej 'a = 1ee2'                 'double e'
rej 'a = 1e2e3'                'two exponents'
rej 'a = 0.0E'                 'exponent with no digits'
rej 'a = 0.0e-'                'exponent sign with no digits'
rej 'a = 0.0e+'                'exponent plus with no digits'
rej 'a = 1e__23'               'double underscore in the exponent'
rej 'a = 1e_23'                'leading underscore in the exponent'
rej 'a = 1e23_'                'trailing underscore in the exponent'
rej 'a = 1_e2'                 'trailing underscore before the exponent'
rej 'a = 1.2_e2'               'trailing underscore in the fraction'
rej 'a = 1._2'                 'underscore after the dot'
rej 'a = 1_.2'                 'underscore before the dot'
rej 'a = 1.2_'                 'trailing underscore in a float'
rej 'a = _1.2'                 'leading underscore in a float'
rej 'a = 03.14'                'leading zero in a float'
rej 'a = -03.14'               'signed leading zero in a float'
rej 'a = Inf'                  'capital Inf'
rej 'a = NaN'                  'capital NaN'
rej 'a = in'                   'truncated inf'
rej 'a = +in'                  'signed truncated inf'
rej 'a = na'                   'truncated nan'
rej 'a = in_f'                 'underscore inside inf'
rej 'a = na_n'                 'underscore inside nan'
rej 'a = infinity'             'the word infinity'
rej 'a = 1.5\0131'              'vertical tab after a float'

# --- the four date-time types ----------------------------------------------
printf '\n--- date-times\n'
acc 'a = 1979-05-27T07:32:00Z'          'offset date-time, Z'
acc 'a = 1979-05-27t07:32:00z'          'offset date-time, lower-case t and z'
acc 'a = 1979-05-27 07:32:00Z'          'offset date-time with a space separator'
acc 'a = 1979-05-27T00:32:00-07:00'     'negative offset'
acc 'a = 1979-05-27T00:32:00+07:00'     'positive offset'
acc 'a = 1979-05-27T00:32:00-00:00'     'the -00:00 unknown-offset form'
acc 'a = 1979-05-27T00:32:00.999-07:00' 'fractional seconds with an offset'
acc 'a = 1979-05-27T00:32:00.999999999999Z' 'twelve fractional digits'
acc 'a = 1979-05-27T07:32:00'           'local date-time'
acc 'a = 1979-05-27 07:32:00'           'local date-time with a space separator'
acc 'a = 1979-05-27T00:32:00.999999'    'local date-time with fractional seconds'
acc 'a = 1979-05-27'                    'local date'
acc 'a = 0001-01-01'                    'the first representable date'
acc 'a = 9999-12-31T23:59:59Z'          'the last representable date-time'
acc 'a = 07:32:00'                      'local time'
acc 'a = 00:32:00.999'                  'local time with fractional seconds'
acc 'a = 1979-05-27 # comment'          'a local date followed by a comment'
acc 'a = 1988-02-29'                    'February 29th in a leap year'
acc 'a = 2000-02-29'                    'February 29th in a 400-year leap year'
acc 'a = 1990-12-31T23:59:60Z'          'a leap second'
acc 'a = 23:59:60'                      'a leap second as a local time'
acc 'a = 1979-05-27T00:32:00+23:59'     'the largest legal offset'
rej 'a = 1987-07-05T17:45Z'             'no seconds'
rej 'a = 1987-07-05T17:45'              'no seconds, local'
rej 'a = 17:45'                         'local time with no seconds'
rej 'a = 1:32:00'                        'one-digit hour'
rej 'a = 01:32:0'                        'one-digit second'
rej 'a = 24:00:00'                       'hour 24'
rej 'a = 00:60:00'                       'minute 60'
rej 'a = 00:00:61'                       'second 61'
rej 'a = 2006-01-01T00:00:61-00:00'      'second 61 with an offset'
rej 'a = 2100-02-29'                     'February 29th in a non-leap century'
rej 'a = 1988-02-30'                     'February 30th'
rej 'a = 1988-13-01'                     'month 13'
rej 'a = 1988-00-01'                     'month zero'
rej 'a = 1988-01-00'                     'day zero'
rej 'a = 1988-01-32'                     'day 32'
rej 'a = 1988-04-31'                     'April 31st'
rej 'a = 10000-01-01'                    'a five-digit year'
rej 'a = 1988-1-01'                      'one-digit month'
rej 'a = 1988-01-1'                      'one-digit day'
acc 'a = 19880101'                       'a date with no separators is just an integer'
rej 'a = 1988/01/01'                     'slashes instead of dashes'
rej 'a = 1988-01-01T'                    'T with no time'
rej 'a = 1988-01-01T07:32:00.'           'fractional second with no digits'
rej 'a = 1988-01-01T07:32:00.Z'          'fractional dot then Z'
rej 'a = 12:13:14..'                     'two trailing dots'
rej 'a = 1988-01-01TZ'                   'T then Z with no time'
rej 'a = 1988-01-01T07:32:00+07'         'offset with no minutes'
rej 'a = 1988-01-01T07:32:00+0730'       'offset with no colon'
rej 'a = 1988-01-01T07:32:00+7:30'       'offset with a one-digit hour'
rej 'a = 1988-01-01T07:32:00-7:30'       'negative offset with a one-digit hour'
rej 'a = 1988-01-01T07:32:00+24:00'      'offset hour 24'
rej 'a = 1988-01-01T07:32:00+07:60'      'offset minute 60'
rej 'a = 1988-01-01T07:32:00x'           'trailing letter'
rej 'a = 1988-01-0107:32:00Z'            'no date-time separator'
rej 'a = 07:32:00Z'                      'a local time cannot take an offset'

# --- table headers ---------------------------------------------------------
printf '\n--- table headers\n'
acc '[a]'                           'an empty table'
acc '[a]\nb = 1'                    'a table with one key'
acc '[ a ]'                         'whitespace inside the brackets'
acc '[a.b]'                         'a dotted header'
acc '[a . b]'                       'whitespace around the dot'
acc '[a.b.c]\nx = 1'                'a three-deep header'
acc '["a"]\nx = 1'                  'a quoted header'
acc "['a']\nx = 1"                  'a literal-string header'
acc '["a.b"]\nx = 1'                'a quoted header with a dot inside the key'
acc '[""]\nx = 1'                   'an empty quoted header'
acc '[a]\n[b]'                      'two tables'
acc '[a]\nx = 1\n[b]\nx = 1'        'the same key in two tables'
acc '[a.b.c]\nx = 1\n[a]\ny = 1'    'a super-table defined after its child'
acc '[a]\ny = 1\n[a.b.c]\nx = 1'    'a super-table defined before its child'
acc '[a] # comment'                 'a comment after a header'
acc '[a]\n[a.b]\n[a.b.c]'           'nested headers in order'
rej '[]'                            'an empty header'
rej '[.]'                           'a header that is only a dot'
rej '[..]'                          'a header of two dots'
rej '[a.]'                          'a header with a trailing dot'
rej '[.a]'                          'a header with a leading dot'
rej '[a..b]'                        'a header with an empty middle part'
rej '[a'                            'an unclosed header'
rej '['                             'a lone open bracket'
rej '[a\n]'                         'a newline inside a header'
rej '[a]b]'                         'a stray closing bracket'
rej '[a[b]'                         'a stray opening bracket'
rej '[ [a]]'                        'a space between the brackets'
rej '[a] x = 1'                     'text after a header'
rej '[a=b]'                         'an equals sign in a header'
rej '[a b]'                         'whitespace inside a bare header key'
rej '[a#b]'                         'a hash inside a header key'
rej '[a!]'                          'an invalid character in a header key'
rej '["""a"""]'                     'a multi-line basic string header'
rej "['''a''']"                     'a multi-line literal string header'
rej '["a\nb"]'                      'a newline inside a quoted header'
rej '[a]\n[a]'                      'the same table twice'
rej '[a]\nb = 1\n[a]\nc = 2'        'the same table twice with keys'
rej '[a]\nb = 1\n[a.b]\nc = 2'      'a header over a key that is an integer'
rej '[a]\nb = 1\n[a.b.c.d]'         'a header descending through an integer'
rej 'a = 1\n[a.b.c.d]'              'a header descending through a top-level integer'
rej '[a.b]\n[a]\n[a]'               'an implicit table made explicit twice'
rej '[a.b]\nc = 1\n[a]\n[a.b]\nc = 2' 'a child table redefined after its parent'

# --- dotted keys -----------------------------------------------------------
printf '\n--- dotted keys\n'
acc 'a.b = 1'                        'a dotted key'
acc 'a.b.c.d = 1'                    'a four-deep dotted key'
acc 'a . b = 1'                      'whitespace around the dot'
acc 'a.b = 1\na.c = 2'               'two dotted keys sharing a prefix'
acc 'a.b = 1\na.c.d = 2'             'two dotted keys sharing one level'
acc 'a.b.c = 1\na.b.d = 2'           'two dotted keys sharing two levels'
acc '"a".b = 1'                      'a quoted first part'
acc 'a."b.c" = 1'                    'a quoted part containing a dot'
acc 'a."" = 1'                       'an empty quoted part'
acc '[t]\nb.c = 1\nb.d = 2'          'dotted keys inside a table'
acc '3.14159 = "pi"'                 'a dotted key that looks like a float'
rej 'a.b = 1\na.b = 2'               'the same dotted key twice'
rej 'a.b.c = 1\na.b = 2'             'redefining an intermediate table as a value'
rej 'a = 1\na.b = 2'                 'extending an integer with a dotted key'
rej 'a = false\na.b = true'          'extending a boolean with a dotted key'
rej 'a.b = 1\na.b.c = 2'             'extending an integer through a dotted key'
rej '. = 1'                          'a key that is only a dot'
rej '.. = 1'                         'two dots as a key'
rej '.a = 1'                         'a leading dot'
rej 'a. = 1'                         'a trailing dot'
rej 'a..b = 1'                       'an empty middle part'
rej 'fs. = 1'                        'a trailing dot with a value'
rej 'fs.fw'                          'a dotted key with no value'
rej 'a.\nb = 1'                      'a newline after the dot'
rej '[a.b.c]\nz = 9\n[a]\nb.c.t = 1' 'a dotted key reaching into an explicit table'
rej '[a.b.c.d]\nz = 9\n[a]\nb.c.d.k.t = 1' 'a deeper dotted key reaching into an explicit table'
rej '[a.b.c]\nz = 9\n[q]\nx = 1\n[a]\nb.c.t = 1' 'the same, with an unrelated table in between'
rej '[t1]\nt2.t3.v = 0\n[t1.t2]'     'a header over a table made by a dotted key'
rej '[t1]\nt2.t3.v = 0\n[t1.t2.t3]'  'a header over a deeper dotted-key table'
rej '[fruit]\napple.color = "red"\n[fruit.apple]' 'the spec example of a dotted-key clash'
rej '[fruit]\napple.taste.sweet = true\n[fruit.apple.taste]' 'the same, one level deeper'

# --- inline tables ---------------------------------------------------------
printf '\n--- inline tables\n'
acc 'a = {}'                          'an empty inline table'
acc 'a = {  }'                        'an empty inline table with spaces'
acc 'a = {b = 1}'                     'one key'
acc 'a = { b = 1 }'                   'one key with spaces'
acc 'a = {b = 1, c = 2}'              'two keys'
acc 'a = {b = 1,c = 2}'               'no space after the comma'
acc 'a = {b = {c = {}}}'              'nested inline tables'
acc 'a = {b.c = 1}'                   'a dotted key inside an inline table'
acc 'a = {b.c = 1, b.d = 2}'          'two dotted keys sharing a prefix inside'
acc 'a = {"b" = 1}'                   'a quoted key inside'
acc 'a = {b = "x", c = 1979-05-27, d = inf}' 'mixed value types inside'
acc '[t]\na = {b = 1}'                'an inline table inside a table'
rej 'a = {'                           'an unterminated inline table'
rej 'a = {b = 1'                      'an unterminated inline table with a key'
rej 'a = }'                           'a lone closing brace'
rej 'a = {,}'                         'a lone comma'
rej 'a = {b = 1,}'                    'a trailing comma'
rej 'a = {b = 1, }'                   'a trailing comma and a space'
rej 'a = {,b = 1}'                    'a leading comma'
rej 'a = {b = 1,, c = 2}'             'a double comma'
rej 'a = {b = 1 c = 2}'               'a missing comma'
rej 'a = {\nb = 1}'                   'a newline after the opening brace'
rej 'a = {b = 1\n}'                   'a newline before the closing brace'
rej 'a = {b = 1,\nc = 2}'             'a newline after the comma'
rej 'a = {b = }'                      'a key with no value inside'
rej 'a = {b}'                         'a bare key with no value inside'
rej 'a = {b = 1, b = 2}'              'a duplicate key inside'
rej 'a = {b = 1, b.c = 2}'            'a dotted key over a key defined inside'
rej 'a = {b.c = 1, b = 2}'            'a key over a dotted-key table defined inside'
rej 'a = {b = 1}\na = {c = 2}'        'the same inline table key twice'
rej '[a]\nb = {c = 2, d = {}}\n[a.b]\nc = 2' 'a header over an inline table'

# --- arrays ----------------------------------------------------------------
printf '\n--- arrays\n'
acc 'a = []'                          'an empty array'
acc 'a = [  ]'                        'an empty array with spaces'
acc 'a = [1]'                         'one element'
acc 'a = [1, 2, 3]'                   'three elements'
acc 'a = [1,2,3]'                     'no spaces after the commas'
acc 'a = [1, ]'                       'a trailing comma'
acc 'a = [1,]'                        'a trailing comma with no space'
acc 'a = [\n1,\n2,\n]'                'newlines and a trailing comma'
acc 'a = [\n  1, # one\n  2, # two\n]' 'comments inside an array'
acc 'a = [ # just a comment\n]'       'a comment inside an empty array'
acc 'a = [[1], [2]]'                  'nested arrays'
acc 'a = [[[[[1]]]]]'                 'five levels of nesting'
acc 'a = [1, "two", 3.0, true, 1979-05-27, [], {}]' 'a heterogeneous array'
acc 'a = [{b = 1}, {b = 2}]'          'inline tables inside an array'
acc 'a = ["""x""", 1]'                'a multi-line string inside an array'
acc 'a = [1\n,2]'                     'a newline before the comma'
rej 'a = ['                           'an unterminated array'
rej 'a = [1'                          'an unterminated array with an element'
rej 'a = [1,'                         'an unterminated array after a comma'
rej 'a = ]'                           'a lone closing bracket as a value'
rej 'a = [,]'                         'a lone comma'
rej 'a = [,1]'                        'a leading comma'
rej 'a = [1,,2]'                      'a double comma'
rej 'a = [1 2]'                       'a missing comma'
rej 'a = [1 2,]'                      'a missing comma before a trailing one'
rej 'a = [[1] [2]]'                   'two nested arrays with no comma'
rej 'a = [1]]'                        'an extra closing bracket'
rej 'a = [[1]'                        'an unclosed nested array'
rej 'a = [1] = 2'                     'an array used as a key'
rej 'a = [1] 2'                       'text after an array'

# --- arrays of tables ------------------------------------------------------
printf '\n--- arrays of tables\n'
acc '[[a]]'                           'one empty element'
acc '[[a]]\nb = 1'                    'one element with a key'
acc '[[a]]\nb = 1\n[[a]]\nb = 2'      'two elements'
acc '[[ a ]]'                         'whitespace inside the brackets'
acc '[[a.b]]'                         'a dotted array-of-tables header'
acc '[[a]]\n[[a.b]]\nx = 1'           'a nested array of tables'
acc '[[a]]\n[a.b]\nx = 1'             'a table inside an array element'
acc '[[a]]\nx = 1\n[[a]]\n[a.b]\ny = 2' 'a table inside the second element'
acc '[[albums.songs]]\nname = "x"'    'an implicit super-table'
acc '[[albums.songs]]\nname = "x"\n[albums]\ny = 1' 'the implicit super-table made explicit'
acc '[[a]]\n[[a]]\n[[a]]'             'three empty elements'
acc '[a]\n[[a.b]]\nx = 1'             'an array of tables inside a table'
rej '[[]]'                            'an empty array-of-tables header'
rej '[[a]'                            'only one closing bracket'
rej '[[a'                             'no closing brackets'
rej '[[a]x'                           'junk after one closing bracket'
rej '[[a] ]'                          'a space between the closing brackets'
rej '[ [a]]'                          'a space after the first opening bracket'
rej '[[a]]]'                          'three closing brackets'
rej '[[a.]]'                          'a trailing dot in the header'
rej '[[a]] x = 1'                     'text after the header'
rej '[a]\n[[a]]'                      'a table then an array of tables'
rej '[[a]]\n[a]'                      'an array of tables then a table'
rej 'a = []\n[[a.b]]'                 'appending through a statically defined array'
rej 'a = [1]\n[[a]]'                  'appending to a statically defined array'
rej 'a = true\n[[a]]'                 'appending to a boolean'
rej '[[albums.songs]]\nname = "x"\n[[albums]]\nname = "y"' 'an implicit super-table used as an array'
rej '[[parent.arr]]\n[parent]\narr = 2' 'overwriting the array from its parent table'
rej '[[a]]\nb.y = 1\n[a]\n'           'a table over an array element'
rej '[[a.b]]\n[a]\nb.y = 2'           'a dotted key reaching into an array'

# --- the redefinition rules ------------------------------------------------
# Most of toml-test's invalid/ tree is this one subject.  The matrix is: how
# a table came to exist (header, header prefix, dotted key, inline table,
# [[array]] element) against what tries to touch it afterwards.
printf '\n--- redefinition rules\n'
acc '[a.b.c]\nz = 1\n[a]\nq = 2'      'implicit then explicit, no overlap'
acc '[a]\nq = 2\n[a.b.c]\nz = 1'      'explicit then deeper implicit'
acc '[a]\nb.c = 1\nb.d = 2'           'two dotted keys in the same body'
acc '[a]\nb.c = 1\n[a.d]\nx = 1'      'a dotted key and an unrelated sibling header'
acc 'a.b = 1\n[c]\nd = 2'             'a top-level dotted key then a table'
acc '[[a]]\n[[a]]\n[a.b]\nx = 1'      'a header into the last array element'
acc 'a = {b = {c = 1}}\n[d]\ne = 1'   'a closed inline table beside a table'
rej '[a]\nb = {c = 1}\n[a.b]'         'a header over an inline table'
rej '[a]\nb = {c = 1}\n[a.b.d]'       'a header through an inline table'
rej '[a]\nb = {c = 1}\nb.d = 2'       'a dotted key over an inline table'
rej 'a = {b = 1}\na.c = 2'            'a dotted key into a top-level inline table'
rej '[a]\nb.c = 1\n[a.b]'             'a header over a dotted-key table'
acc '[a]\nb.c = 1\n[a.b.d]\nx = 1'    'a header through a dotted-key table, adding a new sub-table'
rej '[a]\nb.c.d = 1\n[a.b.c]'         'a header over a deeper dotted-key table'
acc '[a]\nb.c.d = 1\n[a.b.c.e]\nx = 1' 'a header two levels through a dotted-key table'
rej '[a]\nb.c = 1\n[[a.b]]'           'an array of tables over a dotted-key table'
acc 'a.b = 1\n[[a.c]]'                'an array of tables through a dotted-key table'
rej '[a.b]\nc = 1\n[a]\nb.d = 2'      'a dotted key into a table from a header'
rej '[a]\n[a.b]\n[a.b]'               'the same nested table twice'
rej '[a]\n[a.b]\nc = 1\n[a.b]\nc = 2' 'the same nested table twice with keys'
rej '[a.b]\n[a]\n[a.b]'               'implicit, explicit, then the child again'
rej '[a.b]\nc = 1\n[a]\n[a.b]\nc = 2' 'the same with keys in between'
rej '[a.b]\n[a]\n[a]'                 'the super-table twice'
rej '[fruit]\ntype = "apple"\n[fruit.type]\napple = "yes"' 'a header over a string key'
rej '[fruit]\napple.color = "red"\n[[fruit.apple]]' 'an array of tables over a dotted key'
rej '[dependencies.foo]\nv = 1\n[dependencies]\nl = 2\n[dependencies]\nr = 3' 'a table claimed implicitly then twice explicitly'
rej 'a = 1\n[a.b.c.d]'                'a deep header over an integer'
rej 'a = {}\n[a]'                     'a header over an empty inline table'
rej 'a = {}\n[[a]]'                   'an array of tables over an empty inline table'

# --- the JSON dumper -------------------------------------------------------
# The first checks in this suite that look at the parsed *value* rather than
# the verdict.  Everything before this commit was accept/reject only, so the
# multi-line trimming rules in particular were unproven.  Both sides go
# through printf '%b', so a backslash in the expected JSON is doubled here.
printf '\n--- json dumper\n'
jchk() { # jchk <toml> <expected json>
	got=$(printf '%b' "$1" | ./tomlc -j 2>&1)
	want=$(printf '%b' "$2")
	if [ "$got" = "$want" ]; then ok "dump $1"
	else nok "dump $1 (got [$got] want [$want])"; fi
}
jchk ''                 '{}'
jchk 'a = 1'            '{"a":{"type":"integer","value":"1"}}'
jchk 'a = 0x10'         '{"a":{"type":"integer","value":"16"}}'
jchk 'a = 0o10'         '{"a":{"type":"integer","value":"8"}}'
jchk 'a = 0b10'         '{"a":{"type":"integer","value":"2"}}'
jchk 'a = 1_0'          '{"a":{"type":"integer","value":"10"}}'
jchk 'a = -0'           '{"a":{"type":"integer","value":"0"}}'
jchk 'a = +0'           '{"a":{"type":"integer","value":"0"}}'
jchk 'a = 9223372036854775807'  '{"a":{"type":"integer","value":"9223372036854775807"}}'
jchk 'a = -9223372036854775808' '{"a":{"type":"integer","value":"-9223372036854775808"}}'
jchk 'a = 0.1'          '{"a":{"type":"float","value":"0.1"}}'
jchk 'a = 3.14'         '{"a":{"type":"float","value":"3.14"}}'
jchk 'a = 1e2'          '{"a":{"type":"float","value":"100"}}'
jchk 'a = 3e1_4'        '{"a":{"type":"float","value":"3e+14"}}'
jchk 'a = -0.0'         '{"a":{"type":"float","value":"-0"}}'
jchk 'a = inf'          '{"a":{"type":"float","value":"inf"}}'
jchk 'a = -inf'         '{"a":{"type":"float","value":"-inf"}}'
jchk 'a = nan'          '{"a":{"type":"float","value":"nan"}}'
jchk 'a = -nan'         '{"a":{"type":"float","value":"nan"}}'
jchk 'a = true'         '{"a":{"type":"bool","value":"true"}}'
jchk 'a = false'        '{"a":{"type":"bool","value":"false"}}'
jchk 'a = "x"'          '{"a":{"type":"string","value":"x"}}'
jchk 'a = "\\u0041"'     '{"a":{"type":"string","value":"A"}}'
jchk 'a = "\\u00e9"'     '{"a":{"type":"string","value":"\303\251"}}'
jchk 'a = "\\U0001F600"' '{"a":{"type":"string","value":"\360\237\230\200"}}'
jchk 'a = "\\u0000"'     '{"a":{"type":"string","value":"\\u0000"}}'
jchk 'a = "\\t\\n"'       '{"a":{"type":"string","value":"\\t\\n"}}'
jchk 'a = "a\\"b"'       '{"a":{"type":"string","value":"a\\"b"}}'
jchk "a = 'a\\\\b'"       '{"a":{"type":"string","value":"a\\\\b"}}'
# The multi-line rules.  Each of these has a wrong answer that still parses.
jchk 'a = """\nx"""'     '{"a":{"type":"string","value":"x"}}'
jchk 'a = """\n\nx"""'   '{"a":{"type":"string","value":"\\nx"}}'
jchk 'a = """x\ny"""'    '{"a":{"type":"string","value":"x\\ny"}}'
jchk 'a = """x\r\ny"""'  '{"a":{"type":"string","value":"x\\ny"}}'
jchk 'a = """x\\\n   y"""'        '{"a":{"type":"string","value":"xy"}}'
jchk 'a = """x\\   \n\n\n   y"""' '{"a":{"type":"string","value":"xy"}}'
jchk 'a = """x\\\n"""'            '{"a":{"type":"string","value":"x"}}'
jchk 'a = """"x"""'      '{"a":{"type":"string","value":"\\"x"}}'
jchk 'a = """x""""'      '{"a":{"type":"string","value":"x\\""}}'
jchk 'a = """x"""""'     '{"a":{"type":"string","value":"x\\"\\""}}'
jchk 'a = """x""y"""'    '{"a":{"type":"string","value":"x\\"\\"y"}}'
jchk "a = '''\nx'''"     '{"a":{"type":"string","value":"x"}}'
jchk "a = '''x\\\\ny'''"  '{"a":{"type":"string","value":"x\\\\ny"}}'
jchk "a = '''x''''"      '{"a":{"type":"string","value":"x\047"}}'
# Structure.
jchk 'a = []'            '{"a":[]}'
jchk 'a = [1, 2]'        '{"a":[{"type":"integer","value":"1"},{"type":"integer","value":"2"}]}'
jchk 'a = {}'            '{"a":{}}'
jchk 'a = {b = 1}'       '{"a":{"b":{"type":"integer","value":"1"}}}'
jchk 'a.b.c = 1'         '{"a":{"b":{"c":{"type":"integer","value":"1"}}}}'
jchk '[a]\nb = 1'        '{"a":{"b":{"type":"integer","value":"1"}}}'
jchk '[a.b]\nc = 1'      '{"a":{"b":{"c":{"type":"integer","value":"1"}}}}'
jchk '[[a]]\nb = 1\n[[a]]\nb = 2' '{"a":[{"b":{"type":"integer","value":"1"}},{"b":{"type":"integer","value":"2"}}]}'
jchk '[[a]]\n[a.b]\nc = 1'        '{"a":[{"b":{"c":{"type":"integer","value":"1"}}}]}'
jchk 'a = 1979-05-27T07:32:00Z'   '{"a":{"type":"datetime","value":"1979-05-27T07:32:00Z"}}'
jchk 'a = 1979-05-27t07:32:00z'   '{"a":{"type":"datetime","value":"1979-05-27T07:32:00Z"}}'
jchk 'a = 1979-05-27 07:32:00Z'   '{"a":{"type":"datetime","value":"1979-05-27T07:32:00Z"}}'
jchk 'a = 1979-05-27T07:32:00'    '{"a":{"type":"datetime-local","value":"1979-05-27T07:32:00"}}'
jchk 'a = 1979-05-27'             '{"a":{"type":"date-local","value":"1979-05-27"}}'
jchk 'a = 07:32:00.999'           '{"a":{"type":"time-local","value":"07:32:00.999"}}'
jchk 'a = 1979-05-27T00:32:00-07:00' '{"a":{"type":"datetime","value":"1979-05-27T00:32:00-07:00"}}'
jchk '"" = 1'            '{"":{"type":"integer","value":"1"}}'

# --- toml-test conformance -------------------------------------------------
# github.com/toml-lang/toml-test, MIT, the TOML authors.  Vendored as a 48KB
# tarball under t/ so this needs no network; see README for provenance.  The
# subset is the suite's own tests/files-toml-1.0.0 list, so the denominator is
# their choice and not ours: 208 valid documents with their expected JSON and
# 501 invalid ones.
#
# Any exit status outside {0,1} counts as a failure whatever the filename
# asks for: a segfault satisfies "did not exit 0", so a harness written as
# `! ./tomlc "$f"` scores a crash as a pass.  t/oracle.py does not.
printf '\n--- toml-test conformance (TOML 1.0.0 file list)\n'
CORPUS=$SCRATCH/corpus
if [ ! -f "$CORPUS/files-toml-1.0.0" ]; then
	mkdir -p "$CORPUS"
	tar xzf t/toml-test-1.0.0.tar.gz -C "$CORPUS" 2>/dev/null \
		|| nok "extract t/toml-test-1.0.0.tar.gz"
fi
if [ ! -f "$CORPUS/files-toml-1.0.0" ]; then
	nok "vendored toml-test corpus present"
else
	python3 t/oracle.py suite ./tomlc "$CORPUS" \
		--pin "$SCRATCH/suite.txt" 2>&1 | tee -a "$OUT"
	# The score is asserted, not just printed: a regression has to fail
	# the suite rather than quietly score lower.
	if grep -q '^SCORE valid accepted with the expected value: 208/208$' "$OUT"
	then ok "score: 208/208 valid files accepted with the expected value"
	else nok "score: the valid-file score is not 208/208"; fi
	if grep -q '^SCORE invalid rejected: 501/501$' "$OUT"
	then ok "score: 501/501 invalid files rejected"
	else nok "score: the invalid-file score is not 501/501"; fi
	# And the per-file verdicts are pinned, so a change that keeps the
	# totals but moves a file still fails.
	if diff -u t/suite.expected "$SCRATCH/suite.txt" > "$SCRATCH/suite.diff" 2>&1
	then ok "per-file verdicts match t/suite.expected"
	else nok "per-file verdicts changed"; cat "$SCRATCH/suite.diff"; fi
fi

# --- a second file list, scored as a second number -------------------------
#
# The point of this is the 1.1 spec, and the vendored toml-test
# snapshot is 1.0.0 only: it ships files-toml-1.0.0 and nothing else,
# so there is no 1.1 list to score and that half of the item is
# blocked on a newer snapshot rather than on any code here.
#
# What is NOT blocked is the mechanism. The runner takes the list as a
# parameter now, so dropping in a files-toml-1.1.0 is one flag and a
# second pin rather than a rewrite. Scoring a derived list proves the
# denominator really comes from the file and is not a constant that
# happens to equal 208, which is the way this would quietly stop
# meaning anything.
#
# Two numbers, never one. "1.1 not supported" is a position; "1.1: N
# of M, and here is which files and why" is a measurement, and the two
# cannot share a denominator without one of them becoming useless.
if [ -f "$CORPUS/files-toml-1.0.0" ]; then
	grep '^valid/datetime/' "$CORPUS/files-toml-1.0.0" \
		> "$CORPUS/files-derived" 2>/dev/null
	n=$(grep -c '\.toml$' "$CORPUS/files-derived" 2>/dev/null || echo 0)
	if [ "$n" -lt 5 ]; then
		nok "the derived list has files in it ($n)"
	else
		python3 t/oracle.py suite ./tomlc "$CORPUS" \
			--list files-derived --pin "$SCRATCH/derived.txt" \
			> "$SCRATCH/derived.out" 2>&1
		got=$(sed -n 's/^SCORE valid accepted with the expected value: \([0-9]*\)\/\([0-9]*\)$/\2/p' \
		      "$SCRATCH/derived.out")
		if [ "$got" = "$n" ]; then
			ok "a second list is scored on its own denominator ($n files, not 208)"
		else
			nok "the second list's denominator is its own" \
			    "list has $n files, the score says $got"
		fi
	fi

	# A list that exists and names nothing. An empty score satisfies
	# every assertion about a score, so this has to be an error too.
	: > "$CORPUS/files-empty"
	if python3 t/oracle.py suite ./tomlc "$CORPUS" --list files-empty \
	     > "$SCRATCH/empty.out" 2>&1; then
		nok "an empty file list is an error, not a 0/0 score"
	elif grep -q 'lists no .toml files' "$SCRATCH/empty.out"; then
		ok "an empty file list is an error, not a 0/0 score"
	else
		nok "an empty file list is an error" "$(head -1 "$SCRATCH/empty.out")"
	fi

	# A list naming a file the corpus does not have. Skipping it
	# silently shrinks the denominator, which is the quietest way for a
	# conformance number to start lying: the score stays high because
	# the hard cases went missing.
	{ head -3 "$CORPUS/files-toml-1.0.0"; echo "valid/not-here.toml"; } \
		> "$CORPUS/files-ghost"
	if python3 t/oracle.py suite ./tomlc "$CORPUS" --list files-ghost \
	     > "$SCRATCH/ghost.out" 2>&1; then
		nok "a list naming an absent file is an error, not a smaller score"
	elif grep -q 'the corpus does not have' "$SCRATCH/ghost.out"; then
		ok "a list naming an absent file is an error, not a smaller score"
	else
		nok "a list naming an absent file is an error" \
		    "$(head -1 "$SCRATCH/ghost.out")"
	fi

	# A list that is not there must be an error. Scoring zero files and
	# reporting 0/0 would satisfy every assertion ever written about a
	# score, which is the failure this whole section exists to avoid.
	if python3 t/oracle.py suite ./tomlc "$CORPUS" \
	     --list files-toml-9.9.9 > "$SCRATCH/absent.out" 2>&1; then
		nok "a missing file list is an error, not an empty score"
	elif grep -q 'no file list at' "$SCRATCH/absent.out"; then
		ok "a missing file list is an error, not an empty score"
	else
		nok "a missing file list is an error" "$(head -1 "$SCRATCH/absent.out")"
	fi
fi

# --- the differential oracle: Python's tomllib -----------------------------
# A second conforming TOML 1.0.0 implementation, by other people, in another
# language, over the same 709 corpus files plus a named edge battery and 180
# generated documents.  Verdict agreement and value agreement are both
# compared; every disagreement is pinned in t/py_divergences.expected with
# the spec reasoning in the README, so a new one fails the suite.
printf '\n--- differential oracle vs Python tomllib\n'
if [ ! -f "$CORPUS/files-toml-1.0.0" ]; then
	nok "tomllib differential: corpus missing"
elif ! python3 -c 'import tomllib' 2>/dev/null; then
	nok "tomllib differential: python3 has no tomllib (needs 3.11+)"
else
	python3 t/oracle.py tomllib ./tomlc "$CORPUS" \
		--pin "$SCRATCH/py.txt" 2>&1 | tee -a "$OUT"
	# 899, not 900. The leading-UTF-8-BOM edge case used to be a `str`
	# holding five characters, which encodes to six bytes of mojibake --
	# both parsers reject that as a bad key, so it scored as agreement and
	# tested nothing about BOMs. With the real three bytes, tomlc accepts
	# and tomllib rejects, which is a genuine disagreement and is pinned in
	# t/py_divergences.expected.
	if grep -q '^DIFF verdict agreement with tomllib: 899/906$' "$OUT"
	then ok "tomllib verdict agreement is 899/906"
	else nok "tomllib verdict agreement changed"; fi
	if grep -q '^DIFF value agreement with tomllib: 282/284$' "$OUT"
	then ok "tomllib value agreement is 282/284"
	else nok "tomllib value agreement changed"; fi
	# A document that crashed rather than parsing or rejecting is not a
	# disagreement with tomllib and is not an agreement either -- and the
	# differential used to fold it into agreement, because our_parse
	# returned the same (False, None) for exit 1 and for exit 139, and
	# tomllib rejects an invalid document too. Asserted on its own line so
	# the two agreement figures above cannot absorb it.
	if grep -q '^DIFF documents that crashed rather than parsing or rejecting: 0$' "$OUT"
	then ok "no document crashed rather than parsing or rejecting"
	else nok "tomlc crashed on at least one document"
	     grep '^DIVERGENCE.*CRASH' "$OUT" | head -5; fi
	if diff -u t/py_divergences.expected "$SCRATCH/py.txt" > "$SCRATCH/py.diff" 2>&1
	then ok "the 8 tomllib divergences match t/py_divergences.expected"
	else nok "the tomllib divergences changed"; cat "$SCRATCH/py.diff"; fi
fi

# --- the truncation sweep --------------------------------------------------
# Every prefix of every corpus file, parsed and freed in one process.  The
# verdicts are meaningless; the point is that no truncated document crashes,
# overruns, hangs or leaks.  `make test-asan` is where that gets proved --
# under plain gcc this section only catches a crash.
printf '\n--- truncation sweep over the corpus\n'
if [ ! -f "$CORPUS/files-toml-1.0.0" ]; then
	nok "truncation sweep: corpus missing"
else
	bad=0
	total=0
	for f in $(grep '\.toml$' "$CORPUS/files-toml-1.0.0"); do
		out=$(./tomlc -S "$CORPUS/$f" 2>&1)
		st=$?
		if [ "$st" -ne 0 ]; then
			bad=$((bad + 1))
			printf 'SWEEP FAILED exit %s: %s\n%s\n' "$st" "$f" "$out"
		else
			n=${out#swept }
			total=$((total + ${n%% *}))
		fi
	done
	say "SWEEP $total truncated documents parsed across 709 corpus files"
	if [ "$bad" -eq 0 ]
	then ok "every prefix of every corpus file parsed without crashing"
	else nok "$bad corpus files crashed during the truncation sweep"; fi
	if [ "$total" -gt 40000 ]
	then ok "the sweep really ran ($total parses, not zero)"
	else nok "the sweep parsed only $total documents, which is too few"; fi
fi

# The shapes the corpus does not contain: an escape cut in half, a multi-line
# delimiter cut between its quotes, a date-time cut at every field boundary,
# an inline table cut mid-key.
printf '\n--- truncation sweep over hand-written edge shapes\n'
for s in 'a = "\\u0041"' 'a = """x\\\n  y"""' "a = '''x''''" 'a = 1979-05-27T00:32:00.999-07:00' \
	 'a = {b.c = 1, d = [1, {e = 2}]}' '[[a.b]]\nc.d = 1\n[a]\nb = 2' \
	 'a = """x""""' 'a = 0xdead_beef' 'a = """\\\n"""' '[a]\nb.c = 1\n[a.b.d]\nx = 1'; do
	printf '%b' "$s" > "$SCRATCH/sweep.toml"
	if ./tomlc -S "$SCRATCH/sweep.toml" > /dev/null 2>&1
	then ok "sweep $s"
	else nok "sweep $s"; fi
done

# --- hostile input ---------------------------------------------------------
# Not an oracle, a smoke test: random bytes must be rejected, not crash.
printf '\n--- hostile input\n'
head -c 400000 /dev/urandom > "$SCRATCH/random.bin"
./tomlc "$SCRATCH/random.bin" > /dev/null 2>&1
st=$?
if [ "$st" -eq 0 ] || [ "$st" -eq 1 ]
then ok "400kB of /dev/urandom: exit $st"
else nok "400kB of /dev/urandom: exit $st"; fi
if ./tomlc -S "$SCRATCH/random.bin" > /dev/null 2>&1
then ok "truncation sweep over 400kB of /dev/urandom"
else nok "truncation sweep over 400kB of /dev/urandom"; fi
printf 'a = ' > "$SCRATCH/deep.toml"
python3 -c 'print("["*5000 + "]"*5000)' >> "$SCRATCH/deep.toml"
./tomlc "$SCRATCH/deep.toml" > /dev/null 2>&1
if [ $? -eq 1 ]; then ok "5000 nested arrays is an error, not a crash"
else nok "5000 nested arrays"; fi
printf 'a = ' > "$SCRATCH/deep.toml"
python3 -c 'print("{b = "*5000 + "1" + "}"*5000)' >> "$SCRATCH/deep.toml"
./tomlc "$SCRATCH/deep.toml" > /dev/null 2>&1
if [ $? -eq 1 ]; then ok "5000 nested inline tables is an error, not a crash"
else nok "5000 nested inline tables"; fi

# --- error messages --------------------------------------------------------
# The README documents this format, so the format is asserted.  Byte offsets
# alone print as "tomlc: file:1000: ..." which reads as a line number, hence
# line:column with the offset in brackets.
printf '\n--- error messages\n'
msg() { # msg <input> <expected stderr tail>
	got=$(printf '%b' "$1" | ./tomlc 2>&1 >/dev/null)
	want="tomlc: <stdin>:$2"
	if [ "$got" = "$want" ]; then ok "message for $1"
	else nok "message for $1: got [$got] want [$want]"; fi
}
msg 'a = 1\nb = \n'              '2:5: expected a value (byte 10)'
msg 'a = 01\n'                   '1:5: leading zero (byte 4)'
msg '[a]\n[a]\n'                 '2:1: table defined twice (byte 4)'
msg 'a = "x\n'                   '1:5: unterminated string (byte 4)'
msg 'a = 9223372036854775808\n'  '1:5: integer out of range for 64 bits (byte 4)'
msg 'x\n'                        '1:2: expected '"'"'='"'"' after key (byte 1)'
msg 'a = 1\na = 2\n'             '2:1: duplicate key (byte 6)'
msg 'a = {b = 1,}\n'             '1:12: trailing comma in an inline table (byte 11)'
msg '\n\n\na = 1988-02-30\n'     '4:5: day out of range for that month (byte 7)'
msg 'a = 1\nb'                   '2:2: expected '"'"'='"'"' after key (byte 7)'

pass=$(grep -c '^ok - ' "$OUT")
fail=$(grep -c '^not ok - ' "$OUT")
printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
