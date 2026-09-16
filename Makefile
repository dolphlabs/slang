CC     = cc
VERSION = 0.1.0
PREFIX ?= /usr/local
DESTDIR ?=
RUNTIME_DIR = $(abspath runtime)
STDLIB_DIR = $(abspath stdlib)
CFLAGS = -std=c11 -O2 -Wall -Wextra -D_GNU_SOURCE \
	-DSLANG_RUNTIME_DIR=\"$(RUNTIME_DIR)\" \
	-DSLANG_STDLIB_DIR=\"$(STDLIB_DIR)\" \
	-DSLANG_VERSION=\"$(VERSION)\"

# Core codegen engine (type inference, expr/stmt codegen, program
# orchestration) plus native.c, the fixed-signature dispatch every
# pkg_*/sigs.c table plugs into. Runtime C lives in runtime/ and is
# spliced into generated programs at compile time.
CODEGEN_SRCS = src/codegen/core.c src/codegen/infer.c src/codegen/expr.c \
              src/codegen/stmt.c src/codegen/native.c \
              src/codegen/program.c \
              src/codegen/liveness.c \
              src/codegen/escape.c \
              src/codegen/move.c \
              src/codegen/mir.c \
              src/codegen/borrow.c

# Native packages: signatures (and json's generic dispatch) stay in
# src/codegen/pkg_<name>/. Their C runtimes are runtime/sl_*.c.
PKG_SRCS = src/codegen/pkg_time/sigs.c \
          src/codegen/pkg_net/sigs.c \
          src/codegen/pkg_json/dispatch.c \
          src/codegen/pkg_proc/sigs.c \
          src/codegen/pkg_fs/sigs.c \
          src/codegen/pkg_log/sigs.c \
          src/codegen/pkg_crypto/sigs.c \
          src/codegen/pkg_sql/sigs.c \
          src/codegen/pkg_regex/sigs.c src/codegen/pkg_os/sigs.c src/codegen/pkg_strings/sigs.c \
          src/codegen/pkg_encoding/sigs.c \
          src/codegen/pkg_compress/sigs.c

SRCS = src/main.c src/loader.c src/lexer.c src/parser.c src/rtpath.c \
      src/project.c \
      $(CODEGEN_SRCS) $(PKG_SRCS)
HDRS = src/common.h src/lexer.h src/ast.h src/parser.h src/codegen.h \
      src/rtpath.h src/project.h \
      src/codegen/internal.h src/codegen/liveness.h src/codegen/mir.h \
      src/codegen/pkg_net/pkg_net.h \
      src/codegen/pkg_time/pkg_time.h src/codegen/pkg_json/pkg_json.h \
      src/codegen/pkg_proc/pkg_proc.h \
      src/codegen/pkg_fs/pkg_fs.h \
      src/codegen/pkg_log/pkg_log.h \
      src/codegen/pkg_crypto/pkg_crypto.h \
      src/codegen/pkg_sql/pkg_sql.h \
      src/codegen/pkg_regex/pkg_regex.h src/codegen/pkg_os/pkg_os.h src/codegen/pkg_strings/pkg_strings.h \
      src/codegen/pkg_encoding/pkg_encoding.h \
      src/codegen/pkg_compress/pkg_compress.h
RT_SRCS = runtime/sl_core.c runtime/sl_gc.c runtime/sl_containers.c \
         runtime/sl_sched.c runtime/sl_pool.c runtime/sl_time.c \
         runtime/sl_net.c runtime/sl_tls.c runtime/sl_json.c \
         runtime/sl_proc.c runtime/sl_fs.c runtime/sl_log.c \
         runtime/sl_crypto.c runtime/sl_sql.c runtime/sl_regex.c runtime/sl_os.c runtime/sl_strings.c \
         runtime/sl_encoding.c runtime/sl_compress.c

slangc: $(SRCS) $(HDRS) $(RT_SRCS)
	$(CC) $(CFLAGS) -o slangc $(SRCS)

tests/runtime/test_gc: tests/runtime/test_gc.c $(RT_SRCS)
	$(CC) -std=c11 -O2 -Wall -Wno-unused-function -I runtime \
		tests/runtime/test_gc.c -lpthread -o tests/runtime/test_gc

.PHONY: test clean docs docs-serve install uninstall dist slangc-dist

test: slangc tests/runtime/test_gc
	./tests/runtime/test_gc
	./slangc examples/hello/main.sl --run
	./slangc examples/fib/main.sl --run
	./slangc examples/pkgdemo/main.sl --run
	sh tests/run_tests.sh

clean:
	rm -f slangc hello main fib bytes ints lists fail_narrow fail_index \
		tests/runtime/test_gc

# Documentation site. Generated from this repository -- README.md
# sections, the compiler's own signature tables, and the `pub`
# declarations in stdlib/ -- so it cannot drift from the code.
# Output lands in docs/, which GitHub Pages serves directly.
docs:
	python3 www/build.py

docs-serve: docs
	python3 -m http.server -d docs 8000

# ---- installation ---------------------------------------------------
#
# slangc needs its runtime/ and stdlib/ at COMPILE time -- it splices the
# runtime C into every program it builds -- so installing the binary
# alone produces a compiler that cannot compile anything. Both trees go
# to $(PREFIX)/lib/slang, which rtpath.c finds relative to argv0.
#
# The installed binary is built WITHOUT -DSLANG_RUNTIME_DIR /
# -DSLANG_STDLIB_DIR. Those bake absolute paths into this working copy,
# and they are checked before the argv0-relative lookup -- so an
# installed binary carrying them would quietly keep using the source
# tree it was built from, and would break the day that tree moved.
DIST_CFLAGS = -std=c11 -O2 -Wall -Wextra -D_GNU_SOURCE \
	-DSLANG_VERSION=\"$(VERSION)\"

slangc-dist: $(SRCS) $(HDRS) $(RT_SRCS)
	$(CC) $(DIST_CFLAGS) -o slangc-dist $(SRCS)

install: slangc-dist
	mkdir -p $(DESTDIR)$(PREFIX)/bin
	mkdir -p $(DESTDIR)$(PREFIX)/lib/slang/runtime
	mkdir -p $(DESTDIR)$(PREFIX)/lib/slang/stdlib
	cp slangc-dist $(DESTDIR)$(PREFIX)/bin/slangc
	chmod 755 $(DESTDIR)$(PREFIX)/bin/slangc
	cp runtime/*.c $(DESTDIR)$(PREFIX)/lib/slang/runtime/
	cp -R stdlib/. $(DESTDIR)$(PREFIX)/lib/slang/stdlib/
	@echo
	@echo "installed slangc $(VERSION) -> $(DESTDIR)$(PREFIX)/bin/slangc"
	@echo "         runtime + stdlib -> $(DESTDIR)$(PREFIX)/lib/slang"
	@echo
	@echo "try:  slangc new hello && cd hello && slangc main.sl --run"

uninstall:
	rm -f $(DESTDIR)$(PREFIX)/bin/slangc
	rm -rf $(DESTDIR)$(PREFIX)/lib/slang
	@echo "removed slangc and $(DESTDIR)$(PREFIX)/lib/slang"

# A relocatable tarball with the same layout install produces, so a
# release asset can be unpacked anywhere and used in place.
DIST_NAME = slang-$(VERSION)-$(shell uname -s | tr A-Z a-z)-$(shell uname -m)
dist: slangc-dist
	rm -rf dist/$(DIST_NAME)
	mkdir -p dist/$(DIST_NAME)/bin dist/$(DIST_NAME)/lib/slang/runtime
	mkdir -p dist/$(DIST_NAME)/lib/slang/stdlib
	cp slangc-dist dist/$(DIST_NAME)/bin/slangc
	cp runtime/*.c dist/$(DIST_NAME)/lib/slang/runtime/
	cp -R stdlib/. dist/$(DIST_NAME)/lib/slang/stdlib/
	cp README.md LICENSE dist/$(DIST_NAME)/ 2>/dev/null || \
		cp README.md dist/$(DIST_NAME)/
	tar -czf dist/$(DIST_NAME).tar.gz -C dist $(DIST_NAME)
	@echo "wrote dist/$(DIST_NAME).tar.gz"
