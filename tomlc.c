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
	char *s; size_t slen;		/* string bytes, or the date-time text */
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

/* ------------------------------------------------------------------ parser */

static int parse_doc(P *p)
{
	p->root = node(p, TOML_TABLE);
	p->root->flags = F_EXPLICIT;
	p->root->epoch = ++p->epoch;
	for (;;) {
		if (!skip_blank(p)) return 0;
		if (EOFP(p)) return 1;
		return err(p, p->pos, "expected a key or a table header");
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
