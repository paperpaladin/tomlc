# tomlc -- SPDX-License-Identifier: GPL-3.0-or-later
#
# t/run.sh compiles tomlc itself, so test-asan is nothing but a CFLAGS
# override.  -ffile-prefix-map keeps the build reproducible: without it -g
# writes $(CURDIR) into DWARF .debug_line_str.

# GNU make predefines CC as `cc`, so ?= would never fire.
ifeq ($(origin CC),default)
CC = gcc
endif
CFLAGS  ?= -std=c11 -Wall -Wextra -Wpedantic -O2 -g -ffile-prefix-map=$(CURDIR)=.
ASAN     = -std=c11 -Wall -Wextra -Wpedantic -O1 -g -ffile-prefix-map=$(CURDIR)=. \
	   -fsanitize=address,undefined -fno-omit-frame-pointer

.PHONY: all test test-asan clean

all: tomlc

tomlc: tomlc.c
	$(CC) $(CFLAGS) -o $@ tomlc.c -lm

test: all
	CC='$(CC)' CFLAGS='$(CFLAGS)' ./t/run.sh

# We parse untrusted bytes and sweep every truncation of the corpus, which is
# exactly the shape of bug the sanitizers catch.  Not optional.
test-asan:
	CC='$(CC)' CFLAGS='$(ASAN)' UBSAN_OPTIONS=print_stacktrace=1:halt_on_error=1 \
		ASAN_OPTIONS=detect_leaks=1 ./t/run.sh

clean:
	rm -f tomlc
	rm -rf scratch
