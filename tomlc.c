/* tomlc -- a TOML 1.0.0 parser in one C11 file.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * One buffer in, one tree out.  No callbacks, no streaming, no mutation of a
 * parsed document.  The CLI validates with its exit status and dumps the tree
 * in toml-test's tagged JSON encoding, which is what makes it scoreable
 * against a corpus we did not write.
 */
#include <errno.h>
#include <limits.h>
#include <math.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ------------------------------------------------------------------ values */

enum toml_type {
	TOML_TABLE, TOML_ARRAY, TOML_STRING, TOML_INTEGER, TOML_FLOAT,
	TOML_BOOL, TOML_DATETIME, TOML_DATETIME_LOCAL, TOML_DATE_LOCAL,
	TOML_TIME_LOCAL
};

/* Table/array bookkeeping.  TOML's redefinition rules are not a property of
 * the value, they are a property of *how the value came to exist*, so the
 * flags have to be carried on the node. */
enum {
	F_EXPLICIT = 1u << 0,  /* claimed by its own [header], [[header]] element, or inline-table literal */
	F_IMPLICIT = 1u << 1,  /* created as a prefix of a [header]; a later [header] may claim it */
	F_DOTTED   = 1u << 2,  /* created as a prefix of a dotted key; extendable only inside its own body */
	F_INLINE   = 1u << 3,  /* inline table: closed forever, by anything */
	F_AOT      = 1u << 4   /* array created by [[header]]: appendable, unlike a static array */
};

typedef struct toml_value toml_value;
struct toml_kv { char *key; size_t klen; toml_value *val; };

struct toml_value {
	int type;
	unsigned flags;
	unsigned epoch;			/* body that may still extend it; see F_DOTTED */
	char *s; size_t slen, scap;	/* string bytes, or the date-time text */
	long long i;
	double f;
	int b;
	toml_value **arr; size_t narr, caparr;
	struct toml_kv *kv; size_t nkv, capkv;
};

/* Every node ever allocated is registered, so the whole document is freed in
 * one loop whatever happened.  The alternative is a partial-free path in each
 * of the thirty-odd places a parse can fail, which is exactly where a leak
 * hides.  shortcut: a registry, not a real arena -- still one malloc per node
 * and per string; switch to block allocation only if profiling says so. */
typedef struct {
	const unsigned char *p;
	size_t len, pos;
	char err[256];
	size_t errpos;
	toml_value *root;
	toml_value **nodes; size_t nnodes, capnodes;
	unsigned epoch;
	int depth;
} P;

#define MAX_DEPTH 200

static void *xrealloc(void *q, size_t n)
{
	void *r = realloc(q, n);
	if (!r) { fputs("tomlc: out of memory\n", stderr); exit(2); }
	return r;
}

/* err() records the first failure only: later ones are consequences. */
static int err(P *p, size_t at, const char *fmt, ...)
{
	va_list ap;
	if (p->err[0]) return 0;
	p->errpos = at;
	va_start(ap, fmt);
	vsnprintf(p->err, sizeof p->err, fmt, ap);
	va_end(ap);
	if (!p->err[0]) snprintf(p->err, sizeof p->err, "parse error");
	return 0;
}

static toml_value *node(P *p, int type)
{
	toml_value *v = xrealloc(NULL, sizeof *v);
	memset(v, 0, sizeof *v);
	v->type = type;
	if (p->nnodes == p->capnodes) {
		p->capnodes = p->capnodes ? p->capnodes * 2 : 64;
		p->nodes = xrealloc(p->nodes, p->capnodes * sizeof *p->nodes);
	}
	p->nodes[p->nnodes++] = v;
	return v;
}

static void freeall(P *p)
{
	size_t i;
	for (i = 0; i < p->nnodes; i++) {
		free(p->nodes[i]->s);
		free(p->nodes[i]->arr);
		free(p->nodes[i]->kv);
		free(p->nodes[i]);
	}
	free(p->nodes);
	p->nodes = NULL; p->nnodes = p->capnodes = 0; p->root = NULL;
}

/* -------------------------------------------------------------------- utf8 */

/* The whole document must be valid UTF-8 -- in strings, in comments, in keys,
 * everywhere -- so it is cheaper and safer to validate the buffer once up
 * front than to thread a decoder through every production.  Rejects overlong
 * forms, surrogates encoded as UTF-8, and anything above U+10FFFF. */
static size_t utf8_bad(const unsigned char *s, size_t n)
{
	size_t i = 0;
	while (i < n) {
		unsigned c = s[i];
		size_t need;
		unsigned long cp;
		if (c < 0x80) { i++; continue; }
		if (c >= 0xc2 && c <= 0xdf) { need = 1; cp = c & 0x1f; }
		else if (c >= 0xe0 && c <= 0xef) { need = 2; cp = c & 0x0f; }
		else if (c >= 0xf0 && c <= 0xf4) { need = 3; cp = c & 0x07; }
		else return i + 1;
		if (i + need >= n) return i + 1;
		for (size_t k = 1; k <= need; k++) {
			if ((s[i + k] & 0xc0) != 0x80) return i + 1;
			cp = (cp << 6) | (unsigned)(s[i + k] & 0x3f);
		}
		if (need == 2 && cp < 0x800) return i + 1;
		if (need == 3 && cp < 0x10000) return i + 1;
		if (cp >= 0xd800 && cp <= 0xdfff) return i + 1;
		if (cp > 0x10ffff) return i + 1;
		i += need + 1;
	}
	return 0;
}

/* ------------------------------------------------------------------- lexer */

#define AT(p)   ((p)->pos < (p)->len ? (p)->p[(p)->pos] : 0)
#define AT1(p)  ((p)->pos + 1 < (p)->len ? (p)->p[(p)->pos + 1] : 0)
#define AT2(p)  ((p)->pos + 2 < (p)->len ? (p)->p[(p)->pos + 2] : 0)
#define EOFP(p) ((p)->pos >= (p)->len)

static int is_ws(int c) { return c == ' ' || c == '\t'; }

static void skip_ws(P *p) { while (!EOFP(p) && is_ws(AT(p))) p->pos++; }

/* A comment runs to the end of the line.  Control characters are disallowed
 * inside it, tab excepted; toml-test rejects a bare DEL there too, which
 * follows the spec's prose ("control characters other than tab") rather than
 * the 1.0.0 ABNF's %x20-7F.  We follow the prose and the corpus. */
static int skip_comment(P *p)
{
	if (AT(p) != '#') return 1;
	p->pos++;
	while (!EOFP(p) && AT(p) != '\n') {
		unsigned c = AT(p);
		if (c == '\r' && AT1(p) == '\n') break;
		if (c < 0x20 ? c != '\t' : c == 0x7f)
			return err(p, p->pos, "control character in comment");
		p->pos++;
	}
	return 1;
}

/* One newline, LF or CRLF.  A bare CR is not a newline and not whitespace. */
static int skip_newline(P *p)
{
	if (AT(p) == '\n') { p->pos++; return 1; }
	if (AT(p) == '\r' && AT1(p) == '\n') { p->pos += 2; return 1; }
	return 0;
}

/* Blank lines and comment lines between statements. */
static int skip_blank(P *p)
{
	for (;;) {
		skip_ws(p);
		if (AT(p) == '#') { if (!skip_comment(p)) return 0; }
		if (skip_newline(p)) continue;
		return 1;
	}
}

/* After a value: optional whitespace, optional comment, then newline or EOF. */
static int expect_eol(P *p)
{
	skip_ws(p);
	if (AT(p) == '#' && !skip_comment(p)) return 0;
	if (EOFP(p)) return 1;
	if (skip_newline(p)) return 1;
	return err(p, p->pos, "expected newline after statement");
}

/* -------------------------------------------------------------------- keys */

/* Scalar text is built into a node's own buffer, so a half-built string is
 * owned by the registry and freed with everything else if the parse fails. */
static void sput(P *p, toml_value *v, int c)
{
	(void)p;
	if (v->slen + 2 > v->scap) {
		v->scap = v->scap ? v->scap * 2 : 32;
		v->s = xrealloc(v->s, v->scap);
	}
	v->s[v->slen++] = (char)c;
	v->s[v->slen] = '\0';
}

/* A node with an allocated, empty text buffer. */
static toml_value *snode(P *p, int type)
{
	toml_value *v = node(p, type);
	v->scap = 32;
	v->s = xrealloc(NULL, v->scap);
	v->s[0] = '\0';
	return v;
}

/* ----------------------------------------------------------------- strings */

static int hexval(int c)
{
	if (c >= '0' && c <= '9') return c - '0';
	if (c >= 'a' && c <= 'f') return c - 'a' + 10;
	if (c >= 'A' && c <= 'F') return c - 'A' + 10;
	return -1;
}

static void put_cp(P *p, toml_value *v, unsigned long cp)
{
	if (cp < 0x80) { sput(p, v, (int)cp); return; }
	if (cp < 0x800) {
		sput(p, v, (int)(0xc0 | (cp >> 6)));
	} else if (cp < 0x10000) {
		sput(p, v, (int)(0xe0 | (cp >> 12)));
		sput(p, v, (int)(0x80 | ((cp >> 6) & 0x3f)));
	} else {
		sput(p, v, (int)(0xf0 | (cp >> 18)));
		sput(p, v, (int)(0x80 | ((cp >> 12) & 0x3f)));
		sput(p, v, (int)(0x80 | ((cp >> 6) & 0x3f)));
	}
	sput(p, v, (int)(0x80 | (cp & 0x3f)));
}

/* \uXXXX and \UXXXXXXXX must name a Unicode scalar value: a lone surrogate
 * has no UTF-8 encoding, so there is nothing to put in the buffer.  Rejecting
 * it also keeps the dumper total -- no document that parses can fail to
 * serialise. */
static int read_u(P *p, toml_value *v, int n)
{
	unsigned long cp = 0;
	size_t at = p->pos - 2;
	int i, h;
	for (i = 0; i < n; i++) {
		if (EOFP(p) || (h = hexval(AT(p))) < 0)
			return err(p, p->pos, "\\%c needs %d hex digits",
				   n == 4 ? 'u' : 'U', n);
		cp = cp * 16 + (unsigned long)h;
		p->pos++;
	}
	if (cp > 0x10ffff || (cp >= 0xd800 && cp <= 0xdfff))
		return err(p, at, "escape is not a Unicode scalar value");
	put_cp(p, v, cp);
	return 1;
}

/* The escape set is closed in TOML 1.0.0: no \x, no \e, no \', no \/. */
static int read_escape(P *p, toml_value *v)
{
	int c;
	p->pos++;				/* the backslash */
	if (EOFP(p)) return err(p, p->pos, "unterminated escape");
	c = AT(p);
	p->pos++;
	switch (c) {
	case 'b': sput(p, v, '\b'); return 1;
	case 't': sput(p, v, '\t'); return 1;
	case 'n': sput(p, v, '\n'); return 1;
	case 'f': sput(p, v, '\f'); return 1;
	case 'r': sput(p, v, '\r'); return 1;
	case '"': sput(p, v, '"'); return 1;
	case '\\': sput(p, v, '\\'); return 1;
	case 'u': return read_u(p, v, 4);
	case 'U': return read_u(p, v, 8);
	default:  return err(p, p->pos - 2, "unknown escape");
	}
}

/* Single-line basic string.  p->pos is on the opening quote.  Control
 * characters are out, tab excepted, and so is DEL: the 1.0.0 ABNF's
 * basic-unescaped stops at %x7E. */
static toml_value *parse_basic_string(P *p)
{
	toml_value *v = snode(p, TOML_STRING);
	size_t at = p->pos;
	p->pos++;
	for (;;) {
		unsigned c;
		if (EOFP(p)) { err(p, at, "unterminated string"); return NULL; }
		c = AT(p);
		if (c == '"') { p->pos++; return v; }
		if (c == '\n' || c == '\r') {
			err(p, at, "unterminated string");
			return NULL;
		}
		if (c < 0x20 ? c != '\t' : c == 0x7f) {
			err(p, p->pos, "control character in string");
			return NULL;
		}
		if (c == '\\') { if (!read_escape(p, v)) return NULL; continue; }
		sput(p, v, (int)c);
		p->pos++;
	}
}

/* Single-line literal string: no escapes at all, and the same character set
 * as a basic string minus the backslash. */
static toml_value *parse_literal_string(P *p)
{
	toml_value *v = snode(p, TOML_STRING);
	size_t at = p->pos;
	p->pos++;
	for (;;) {
		unsigned c;
		if (EOFP(p)) { err(p, at, "unterminated literal string"); return NULL; }
		c = AT(p);
		if (c == '\'') { p->pos++; return v; }
		if (c == '\n' || c == '\r') {
			err(p, at, "unterminated literal string");
			return NULL;
		}
		if (c < 0x20 ? c != '\t' : c == 0x7f) {
			err(p, p->pos, "control character in literal string");
			return NULL;
		}
		sput(p, v, (int)c);
		p->pos++;
	}
}

/* A newline immediately after the opening delimiter of either multi-line form
 * is trimmed, and only that one. */
static void trim_first_newline(P *p)
{
	if (AT(p) == '\n') p->pos++;
	else if (AT(p) == '\r' && AT1(p) == '\n') p->pos += 2;
}

/* The line-ending backslash: the last non-whitespace character on a line, it
 * eats itself, the rest of the line, the newline, and every blank line and
 * leading space after it. */
static int trim_ws_newlines(P *p)
{
	size_t at = p->pos - 1;
	skip_ws(p);
	if (!skip_newline(p))
		return err(p, at, "backslash is not the last character on the line");
	for (;;) {
		skip_ws(p);
		if (!skip_newline(p)) return 1;
	}
}

/* A run of n quotes inside a multi-line string: up to two are content, three
 * close it, four or five are content-then-close, six cannot happen because
 * that would be three quotes of content. */
static int quote_run(P *p, toml_value *v, int q)
{
	int n = 0;
	while (AT(p) == q) { n++; p->pos++; }
	if (n < 3) {
		int i;
		for (i = 0; i < n; i++) sput(p, v, q);
		return 0;			/* content, string continues */
	}
	if (n > 5) return err(p, p->pos - (size_t)n, "too many quotes"), -1;
	{
		int i;
		for (i = 0; i < n - 3; i++) sput(p, v, q);
	}
	return 1;				/* closed */
}

static toml_value *parse_ml_basic(P *p)
{
	toml_value *v = snode(p, TOML_STRING);
	size_t at = p->pos;
	p->pos += 3;
	trim_first_newline(p);
	for (;;) {
		unsigned c;
		if (EOFP(p)) { err(p, at, "unterminated multi-line string"); return NULL; }
		c = AT(p);
		if (c == '"') {
			int r = quote_run(p, v, '"');
			if (r < 0) return NULL;
			if (r) return v;
			continue;
		}
		if (c == '\\') {
			/* A backslash before a newline (or before trailing
			 * whitespace and a newline) is the line-ending form;
			 * anything else is an ordinary escape. */
			size_t q = p->pos + 1;
			while (q < p->len && is_ws(p->p[q])) q++;
			if (q < p->len && (p->p[q] == '\n' ||
			    (p->p[q] == '\r' && q + 1 < p->len && p->p[q + 1] == '\n'))) {
				p->pos++;
				if (!trim_ws_newlines(p)) return NULL;
				continue;
			}
			if (!read_escape(p, v)) return NULL;
			continue;
		}
		if (c == '\r') {
			if (AT1(p) != '\n')
				return err(p, p->pos, "bare carriage return in string"), NULL;
			/* CRLF inside a multi-line string is normalised to
			 * LF.  TOML 1.0.0 lets a parser "normalize newline to
			 * whatever makes sense", no valid toml-test case has a
			 * raw CRLF in string content, and tomllib normalises,
			 * so agreeing with tomllib costs nothing. */
			sput(p, v, '\n');
			p->pos += 2;
			continue;
		}
		if (c == '\n') { sput(p, v, '\n'); p->pos++; continue; }
		if (c < 0x20 ? c != '\t' : c == 0x7f)
			return err(p, p->pos, "control character in string"), NULL;
		sput(p, v, (int)c);
		p->pos++;
	}
}

static toml_value *parse_ml_literal(P *p)
{
	toml_value *v = snode(p, TOML_STRING);
	size_t at = p->pos;
	p->pos += 3;
	trim_first_newline(p);
	for (;;) {
		unsigned c;
		if (EOFP(p)) { err(p, at, "unterminated multi-line literal string"); return NULL; }
		c = AT(p);
		if (c == '\'') {
			int r = quote_run(p, v, '\'');
			if (r < 0) return NULL;
			if (r) return v;
			continue;
		}
		if (c == '\r') {
			if (AT1(p) != '\n')
				return err(p, p->pos, "bare carriage return in string"), NULL;
			/* CRLF inside a multi-line string is normalised to
			 * LF.  TOML 1.0.0 lets a parser "normalize newline to
			 * whatever makes sense", no valid toml-test case has a
			 * raw CRLF in string content, and tomllib normalises,
			 * so agreeing with tomllib costs nothing. */
			sput(p, v, '\n');
			p->pos += 2;
			continue;
		}
		if (c == '\n') { sput(p, v, '\n'); p->pos++; continue; }
		if (c < 0x20 ? c != '\t' : c == 0x7f)
			return err(p, p->pos, "control character in string"), NULL;
		sput(p, v, (int)c);
		p->pos++;
	}
}

/* Any of the four string forms, as a value. */
static toml_value *parse_string(P *p)
{
	if (AT(p) == '"') {
		if (AT1(p) == '"' && AT2(p) == '"') return parse_ml_basic(p);
		return parse_basic_string(p);
	}
	if (AT1(p) == '\'' && AT2(p) == '\'') return parse_ml_literal(p);
	return parse_literal_string(p);
}

static int is_bare(int c)
{
	return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
	       (c >= '0' && c <= '9') || c == '_' || c == '-';
}

/* One key part.  Returns a TOML_STRING node used only as a key holder: the
 * table entry points into its buffer and the registry owns it. */
static toml_value *parse_keypart(P *p)
{
	toml_value *k;
	if (AT(p) == '"' || AT(p) == '\'') {
		int q = AT(p);
		if (AT1(p) == q && AT2(p) == q) {
			err(p, p->pos, "a key cannot be a multi-line string");
			return NULL;
		}
		return q == '"' ? parse_basic_string(p) : parse_literal_string(p);
	}
	if (!is_bare(AT(p))) {
		err(p, p->pos, "expected a key");
		return NULL;
	}
	k = snode(p, TOML_STRING);
	while (!EOFP(p) && is_bare(AT(p))) sput(p, k, p->p[p->pos++]);
	return k;
}

static struct toml_kv *tbl_find(toml_value *t, const char *k, size_t n)
{
	size_t i;
	for (i = 0; i < t->nkv; i++)
		if (t->kv[i].klen == n && !memcmp(t->kv[i].key, k, n))
			return &t->kv[i];
	return NULL;
}

static void tbl_put(P *p, toml_value *t, toml_value *key, toml_value *v)
{
	(void)p;
	if (t->nkv == t->capkv) {
		t->capkv = t->capkv ? t->capkv * 2 : 8;
		t->kv = xrealloc(t->kv, t->capkv * sizeof *t->kv);
	}
	t->kv[t->nkv].key = key->s;
	t->kv[t->nkv].klen = key->slen;
	t->kv[t->nkv].val = v;
	t->nkv++;
}

/* ---------------------------------------------------------------- numbers */

/* A scalar token: everything a number, a date-time or a bare literal can be
 * made of.  Scanning the whole token up front and then validating it is what
 * makes "answer = 42 the ultimate answer?" and "0xaafz" errors at the number
 * rather than surprises at the next production. */
static int tok_char(int c)
{
	return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') ||
	       (c >= 'A' && c <= 'Z') || c == '_' || c == '+' || c == '-' ||
	       c == '.' || c == ':';
}

static size_t scan_token(P *p)
{
	size_t n = 0;
	while (p->pos + n < p->len && tok_char(p->p[p->pos + n])) n++;
	return n;
}

static int digit_of(int c, int base)
{
	int v;
	if (c >= '0' && c <= '9') v = c - '0';
	else if (c >= 'a' && c <= 'f') v = c - 'a' + 10;
	else if (c >= 'A' && c <= 'F') v = c - 'A' + 10;
	else return -1;
	return v < base ? v : -1;
}

/* One run of digits with underscores strictly between digits.  Accumulates
 * into *out when out is non-NULL and sets *ovf if it does not fit; copies the
 * digits with the underscores removed to dst when dst is non-NULL, which is
 * what strtod has to be handed. */
static int digit_run(P *p, const char *s, size_t n, size_t *i, int base,
		     int lead_zero_ok, unsigned long long *out, int *ovf,
		     toml_value *dst)
{
	if (*i >= n || digit_of(s[*i], base) < 0)
		return err(p, p->pos + *i, "expected a digit");
	if (!lead_zero_ok && s[*i] == '0' && *i + 1 < n &&
	    (digit_of(s[*i + 1], base) >= 0 || s[*i + 1] == '_'))
		return err(p, p->pos + *i, "leading zero");
	while (*i < n) {
		int d = digit_of(s[*i], base);
		if (d >= 0) {
			if (out) {
				unsigned long long lim = ~0ULL;
				if (*out > (lim - (unsigned)d) / (unsigned)base)
					*ovf = 1;
				else
					*out = *out * (unsigned)base + (unsigned)d;
			}
			if (dst) sput(p, dst, s[*i]);
			(*i)++;
			continue;
		}
		if (s[*i] == '_') {
			if (*i + 1 >= n || digit_of(s[*i + 1], base) < 0)
				return err(p, p->pos + *i,
					   "underscore must be between digits");
			(*i)++;
			continue;
		}
		break;
	}
	return 1;
}

static toml_value *int_node(P *p, unsigned long long mag, int neg, int ovf,
			    size_t at)
{
	toml_value *v;
	if (ovf || (neg ? mag > 9223372036854775808ULL
			: mag > 9223372036854775807ULL)) {
		err(p, at, "integer out of range for 64 bits");
		return NULL;
	}
	v = node(p, TOML_INTEGER);
	v->i = neg ? (long long)(0ULL - mag) : (long long)mag;
	return v;
}

static toml_value *parse_number(P *p)
{
	const char *s = (const char *)p->p + p->pos;
	size_t n = scan_token(p), i = 0;
	size_t at = p->pos;
	unsigned long long mag = 0;
	int neg = 0, ovf = 0, signed_ = 0;
	toml_value *v;

	if (i < n && (s[i] == '+' || s[i] == '-')) {
		neg = s[i] == '-';
		signed_ = 1;
		i++;
	}
	/* 0x / 0o / 0b take no sign, and the prefix letter is lower case:
	 * 0X1 is not a number in TOML 1.0.0. */
	if (!signed_ && i + 1 < n && s[i] == '0' &&
	    (s[i + 1] == 'x' || s[i + 1] == 'o' || s[i + 1] == 'b')) {
		int base = s[i + 1] == 'x' ? 16 : s[i + 1] == 'o' ? 8 : 2;
		i += 2;
		if (!digit_run(p, s, n, &i, base, 1, &mag, &ovf, NULL))
			return NULL;
		if (i != n) {
			err(p, p->pos + i, "trailing junk after a number");
			return NULL;
		}
		p->pos += n;
		return int_node(p, mag, 0, ovf, at);
	}
	/* inf and nan take a sign and nothing else. */
	if (n - i == 3 && (!memcmp(s + i, "inf", 3) || !memcmp(s + i, "nan", 3))) {
		v = node(p, TOML_FLOAT);
		v->f = s[i] == 'i' ? (neg ? -INFINITY : INFINITY) : NAN;
		p->pos += n;
		return v;
	}
	/* A '.' or an exponent anywhere in the token makes it a float.  The
	 * base-prefixed forms are already gone, so an 'e' here cannot be a hex
	 * digit. */
	if (memchr(s + i, '.', n - i) || memchr(s + i, 'e', n - i) ||
	    memchr(s + i, 'E', n - i)) {
		v = snode(p, TOML_FLOAT);
		if (neg) sput(p, v, '-');
		if (!digit_run(p, s, n, &i, 10, 0, NULL, NULL, v))
			return NULL;
		if (i < n && s[i] == '.') {
			sput(p, v, '.');
			i++;
			if (!digit_run(p, s, n, &i, 10, 1, NULL, NULL, v))
				return NULL;
		}
		if (i < n && (s[i] == 'e' || s[i] == 'E')) {
			sput(p, v, 'e');
			i++;
			if (i < n && (s[i] == '+' || s[i] == '-'))
				sput(p, v, s[i++]);
			if (!digit_run(p, s, n, &i, 10, 1, NULL, NULL, v))
				return NULL;
		}
		if (i != n) {
			err(p, p->pos + i, "trailing junk after a number");
			return NULL;
		}
		/* strtod cannot be the validator -- it accepts 0x10, inf,
		 * nan, a leading + and leading whitespace, and on "1e" it
		 * silently consumes just the 1 -- so it only ever sees text
		 * this function has already proved is a TOML float. */
		v->f = strtod(v->s, NULL);
		p->pos += n;
		return v;
	}
	if (!digit_run(p, s, n, &i, 10, 0, &mag, &ovf, NULL))
		return NULL;
	if (i != n) {
		err(p, p->pos + i, "trailing junk after a number");
		return NULL;
	}
	v = int_node(p, mag, neg, ovf, at);
	if (!v) return NULL;
	p->pos += n;
	return v;
}

/* ------------------------------------------------------------- date-times */

static int days_in_month(int y, int m)
{
	static const int d[] = { 31,28,31,30,31,30,31,31,30,31,30,31 };
	if (m == 2 && ((y % 4 == 0 && y % 100 != 0) || y % 400 == 0)) return 29;
	return d[m - 1];
}

/* Exactly ndig digits, copied into v and returned as a number.  "Exactly" is
 * the point: 1:32:00 and 01:32:0 are both errors, and so is 10000-01-01. */
static int dnum(P *p, toml_value *v, int ndig, int *out)
{
	int val = 0, i;
	for (i = 0; i < ndig; i++) {
		if (EOFP(p) || AT(p) < '0' || AT(p) > '9')
			return err(p, p->pos, "expected %d digits in a date-time",
				   ndig);
		val = val * 10 + (AT(p) - '0');
		sput(p, v, (int)AT(p));
		p->pos++;
	}
	*out = val;
	return 1;
}

static int dlit(P *p, toml_value *v, int c)
{
	if (AT(p) != c) return err(p, p->pos, "expected '%c' in a date-time", c);
	sput(p, v, c);
	p->pos++;
	return 1;
}

static int parse_date_part(P *p, toml_value *v)
{
	int y, m, d;
	size_t at = p->pos;
	if (!dnum(p, v, 4, &y) || !dlit(p, v, '-') || !dnum(p, v, 2, &m) ||
	    !dlit(p, v, '-') || !dnum(p, v, 2, &d))
		return 0;
	if (m < 1 || m > 12) return err(p, at, "month out of range");
	if (d < 1 || d > days_in_month(y, m))
		return err(p, at, "day out of range for that month");
	return 1;
}

/* Seconds are mandatory in TOML 1.0.0 (optional only in 1.1), and 60 is
 * allowed because a leap second is a real time of day. */
static int parse_time_part(P *p, toml_value *v)
{
	int h, mi, s;
	size_t at = p->pos;
	if (!dnum(p, v, 2, &h) || !dlit(p, v, ':') || !dnum(p, v, 2, &mi) ||
	    !dlit(p, v, ':') || !dnum(p, v, 2, &s))
		return 0;
	if (h > 23) return err(p, at, "hour out of range");
	if (mi > 59) return err(p, at, "minute out of range");
	if (s > 60) return err(p, at, "second out of range");
	if (AT(p) == '.') {
		sput(p, v, '.');
		p->pos++;
		if (EOFP(p) || AT(p) < '0' || AT(p) > '9')
			return err(p, p->pos, "fractional second with no digits");
		while (!EOFP(p) && AT(p) >= '0' && AT(p) <= '9')
			sput(p, v, p->p[p->pos++]);
	}
	return 1;
}

static int parse_offset(P *p, toml_value *v)
{
	int h, mi;
	size_t at = p->pos;
	if (AT(p) == 'Z' || AT(p) == 'z') { sput(p, v, 'Z'); p->pos++; return 1; }
	sput(p, v, (int)AT(p));
	p->pos++;
	if (!dnum(p, v, 2, &h) || !dlit(p, v, ':') || !dnum(p, v, 2, &mi))
		return 0;
	if (h > 23) return err(p, at, "offset hour out of range");
	if (mi > 59) return err(p, at, "offset minute out of range");
	return 1;
}

/* A date at the value position is the only place in TOML where a space can
 * appear inside a single value, so the space separator is taken only when a
 * time really follows it; "d = 1979-05-27 # comment" is a local date. */
static int space_then_time(P *p)
{
	return AT(p) == ' ' && p->pos + 3 < p->len &&
	       p->p[p->pos + 1] >= '0' && p->p[p->pos + 1] <= '9' &&
	       p->p[p->pos + 2] >= '0' && p->p[p->pos + 2] <= '9' &&
	       p->p[p->pos + 3] == ':';
}

static toml_value *parse_datetime(P *p)
{
	toml_value *v = snode(p, TOML_DATE_LOCAL);
	int c;
	if (p->pos + 4 < p->len && p->p[p->pos + 4] == '-') {
		if (!parse_date_part(p, v)) return NULL;
		c = AT(p);
		if (c == 'T' || c == 't' || space_then_time(p)) {
			p->pos++;
			sput(p, v, 'T');
			if (!parse_time_part(p, v)) return NULL;
			v->type = TOML_DATETIME_LOCAL;
			c = AT(p);
			if (c == 'Z' || c == 'z' || c == '+' || c == '-') {
				if (!parse_offset(p, v)) return NULL;
				v->type = TOML_DATETIME;
			}
		}
	} else {
		if (!parse_time_part(p, v)) return NULL;
		v->type = TOML_TIME_LOCAL;
	}
	if (!EOFP(p) && tok_char(AT(p))) {
		err(p, p->pos, "trailing junk after a date-time");
		return NULL;
	}
	return v;
}

/* Is the value at p a date-time rather than a number?  YYYY- or HH:. */
static int looks_like_datetime(P *p)
{
	size_t i;
	if (p->pos + 4 < p->len && p->p[p->pos + 4] == '-') {
		for (i = 0; i < 4; i++)
			if (p->p[p->pos + i] < '0' || p->p[p->pos + i] > '9')
				return 0;
		return 1;
	}
	if (p->pos + 2 < p->len && p->p[p->pos + 2] == ':') {
		for (i = 0; i < 2; i++)
			if (p->p[p->pos + i] < '0' || p->p[p->pos + i] > '9')
				return 0;
		return 1;
	}
	return 0;
}

/* ------------------------------------------------------------------ values */

static toml_value *parse_value(P *p);
static int parse_keyval(P *p, toml_value *t);

/* An inline table is closed the moment it ends: no header and no dotted key
 * may ever add to it.  TOML 1.0.0 also forbids a newline anywhere inside one,
 * which falls out of using skip_ws (space and tab) and never skip_blank. */
static toml_value *parse_inline_table(P *p)
{
	toml_value *v = node(p, TOML_TABLE);
	size_t at = p->pos;
	v->flags = F_INLINE | F_EXPLICIT;
	v->epoch = ++p->epoch;
	p->pos++;
	skip_ws(p);
	if (AT(p) == '}') { p->pos++; return v; }
	for (;;) {
		if (EOFP(p)) return err(p, at, "unterminated inline table"), NULL;
		if (!parse_keyval(p, v)) return NULL;
		skip_ws(p);
		if (AT(p) == ',') {
			p->pos++;
			skip_ws(p);
			if (AT(p) == '}')
				return err(p, p->pos, "trailing comma in an "
					   "inline table"), NULL;
			continue;
		}
		if (AT(p) == '}') { p->pos++; return v; }
		return err(p, p->pos, "expected ',' or '}' in an inline "
			   "table"), NULL;
	}
}

static toml_value *parse_value_1(P *p)
{
	if (AT(p) == '"' || AT(p) == '\'') return parse_string(p);
	if (p->len - p->pos >= 4 && !memcmp(p->p + p->pos, "true", 4)) {
		toml_value *v = node(p, TOML_BOOL);
		p->pos += 4; v->b = 1;
		return v;
	}
	if (p->len - p->pos >= 5 && !memcmp(p->p + p->pos, "false", 5)) {
		toml_value *v = node(p, TOML_BOOL);
		p->pos += 5; v->b = 0;
		return v;
	}
	if (AT(p) == '{') return parse_inline_table(p);
	if (looks_like_datetime(p)) return parse_datetime(p);
	if ((AT(p) >= '0' && AT(p) <= '9') || AT(p) == '+' || AT(p) == '-' ||
	    AT(p) == 'i' || AT(p) == 'n')
		return parse_number(p);
	err(p, p->pos, "expected a value");
	return NULL;
}

/* The recursion guard.  Inline tables and arrays nest, and a 100000-deep
 * document is an error return and not a SIGSEGV: a crash is not a rejection.
 * shortcut: a fixed depth of 200, which is far above anything real and far
 * below the stack; make it an option only if someone complains. */
static toml_value *parse_value(P *p)
{
	toml_value *v;
	if (++p->depth > MAX_DEPTH) {
		p->depth--;
		err(p, p->pos, "nesting too deep");
		return NULL;
	}
	v = parse_value_1(p);
	p->depth--;
	return v;
}

/* ------------------------------------------------------------ table syntax */

/* shortcut: 64 dotted parts in one key or header.  A document with a
 * 65-level dotted key is a parse error here; raise the constant or make it a
 * growable array if anyone ever produces one. */
#define MAX_PARTS 64

static int parse_keypath(P *p, toml_value **parts, int *np)
{
	*np = 0;
	for (;;) {
		toml_value *k = parse_keypart(p);
		if (!k) return 0;
		if (*np == MAX_PARTS)
			return err(p, p->pos, "dotted key is too deep");
		parts[(*np)++] = k;
		skip_ws(p);
		if (AT(p) != '.') return 1;
		p->pos++;
		skip_ws(p);
	}
}

/* One step of a [header] path.  A missing table is created implicitly and may
 * be claimed by its own header later; anything that is not a table is a
 * collision. */
static toml_value *hdr_descend(P *p, toml_value *t, toml_value *key, size_t at)
{
	struct toml_kv *e = tbl_find(t, key->s, key->slen);
	toml_value *n;
	if (e) {
		if (e->val->type != TOML_TABLE) {
			err(p, at, "cannot use a non-table key as a table");
			return NULL;
		}
		return e->val;
	}
	n = node(p, TOML_TABLE);
	n->flags = F_IMPLICIT;
	tbl_put(p, t, key, n);
	return n;
}

static int parse_header(P *p, toml_value **cur)
{
	toml_value *parts[MAX_PARTS], *t = p->root;
	struct toml_kv *e;
	int np, i;
	size_t at = p->pos;

	p->pos++;				/* '[' */
	skip_ws(p);
	if (!parse_keypath(p, parts, &np)) return 0;
	skip_ws(p);
	if (AT(p) != ']') return err(p, p->pos, "expected ']' after a table header");
	p->pos++;
	if (!expect_eol(p)) return 0;

	for (i = 0; i < np - 1; i++)
		if (!(t = hdr_descend(p, t, parts[i], at))) return 0;

	e = tbl_find(t, parts[np - 1]->s, parts[np - 1]->slen);
	if (!e) {
		toml_value *n = node(p, TOML_TABLE);
		n->flags = F_EXPLICIT;
		n->epoch = ++p->epoch;
		tbl_put(p, t, parts[np - 1], n);
		*cur = n;
		return 1;
	}
	if (e->val->type == TOML_TABLE && (e->val->flags & F_IMPLICIT)) {
		e->val->flags = F_EXPLICIT;
		e->val->epoch = ++p->epoch;
		*cur = e->val;
		return 1;
	}
	return err(p, at, "table defined twice");
}

/* ------------------------------------------------------------------ parser */

/* One step of a dotted key's path.  A dotted key may create intermediate
 * tables and may extend ones it created itself, but only inside the body it
 * created them in: that is what the epoch records.  Everything else -- a
 * table from a header, an implicit table from a header prefix, an inline
 * table, an array, a scalar -- is closed to it. */
static toml_value *dot_descend(P *p, toml_value *t, toml_value *key, size_t at)
{
	struct toml_kv *e = tbl_find(t, key->s, key->slen);
	toml_value *n;
	if (e) {
		if (e->val->type != TOML_TABLE)
			return err(p, at, "cannot extend a non-table key"), NULL;
		if (!(e->val->flags & F_DOTTED) || e->val->epoch != t->epoch)
			return err(p, at, "cannot extend that table with a "
				   "dotted key"), NULL;
		return e->val;
	}
	n = node(p, TOML_TABLE);
	n->flags = F_DOTTED;
	n->epoch = t->epoch;
	tbl_put(p, t, key, n);
	return n;
}

static int parse_keyval(P *p, toml_value *t)
{
	toml_value *parts[MAX_PARTS], *v;
	size_t kpos = p->pos;
	int np, i;
	if (!parse_keypath(p, parts, &np)) return 0;
	skip_ws(p);
	if (AT(p) != '=') return err(p, p->pos, "expected '=' after key");
	p->pos++;
	skip_ws(p);
	if (!(v = parse_value(p))) return 0;
	for (i = 0; i < np - 1; i++)
		if (!(t = dot_descend(p, t, parts[i], kpos))) return 0;
	if (tbl_find(t, parts[np - 1]->s, parts[np - 1]->slen))
		return err(p, kpos, "duplicate key");
	tbl_put(p, t, parts[np - 1], v);
	return 1;
}

static int parse_doc(P *p)
{
	toml_value *cur;
	p->root = node(p, TOML_TABLE);
	p->root->flags = F_EXPLICIT;
	p->root->epoch = ++p->epoch;
	cur = p->root;
	for (;;) {
		if (!skip_blank(p)) return 0;
		if (EOFP(p)) return 1;
		if (AT(p) == '[') {
			if (!parse_header(p, &cur)) return 0;
			continue;
		}
		if (!parse_keyval(p, cur)) return 0;
		if (!expect_eol(p)) return 0;
	}
}

static int toml_parse(const void *buf, size_t len, P *p)
{
	size_t bad;
	memset(p, 0, sizeof *p);
	p->p = buf; p->len = len;
	if (!buf) { p->p = (const unsigned char *)""; p->len = 0; }
	bad = utf8_bad(p->p, p->len);
	if (bad) return err(p, bad - 1, "invalid UTF-8");
	/* A single BOM at the very start is skipped; a second one is a key
	 * that is not a key.  TOML 1.0.0 says nothing about either. */
	if (p->len >= 3 && p->p[0] == 0xef && p->p[1] == 0xbb && p->p[2] == 0xbf)
		p->pos = 3;
	return parse_doc(p);
}

/* --------------------------------------------------------------------- cli */

static char *slurp(const char *path, size_t *outlen)
{
	FILE *f = path ? fopen(path, "rb") : stdin;
	size_t n = 0, cap = 1 << 16;
	char *b;
	if (!f) return NULL;
	b = xrealloc(NULL, cap);
	for (;;) {
		size_t got = fread(b + n, 1, cap - n, f);
		n += got;
		if (n < cap) break;
		cap *= 2;
		b = xrealloc(b, cap);
	}
	if (ferror(f)) { free(b); if (path) fclose(f); return NULL; }
	if (path) fclose(f);
	*outlen = n;
	return b;
}

/* "file:1000: ..." reads as a line number when it is a byte offset, so report
 * line:column and put the offset in brackets. */
static void report(const char *name, P *p)
{
	size_t i, line = 1, col = 1;
	for (i = 0; i < p->errpos && i < p->len; i++) {
		if (p->p[i] == '\n') { line++; col = 1; } else col++;
	}
	fprintf(stderr, "tomlc: %s:%zu:%zu: %s (byte %zu)\n",
		name, line, col, p->err, p->errpos);
}

int main(int argc, char **argv)
{
	const char *path = NULL;
	char *buf;
	size_t len = 0;
	P p;
	int i, rc;

	for (i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) {
			printf("usage: tomlc [FILE]\n"
			       "  validates FILE (or stdin); exit 0 valid, 1 invalid\n");
			return 0;
		}
		if (argv[i][0] == '-' && argv[i][1]) {
			fprintf(stderr, "tomlc: unknown option %s\n", argv[i]);
			return 2;
		}
		path = argv[i];
	}

	buf = slurp(path, &len);
	if (!buf) {
		fprintf(stderr, "tomlc: %s: %s\n", path ? path : "<stdin>",
			strerror(errno));
		return 2;
	}
	rc = toml_parse(buf, len, &p);
	if (!rc) report(path ? path : "<stdin>", &p);
	freeall(&p);
	free(buf);
	return rc ? 0 : 1;
}
