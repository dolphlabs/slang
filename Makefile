CC     = cc
RUNTIME_DIR = $(abspath runtime)
STDLIB_DIR = $(abspath stdlib)
CFLAGS = -std=c11 -O2 -Wall -Wextra -D_GNU_SOURCE \
	-DSLANG_RUNTIME_DIR=\"$(RUNTIME_DIR)\" \
	-DSLANG_STDLIB_DIR=\"$(STDLIB_DIR)\"

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
          src/codegen/pkg_proc/sigs.c

SRCS = src/main.c src/loader.c src/lexer.c src/parser.c src/rtpath.c \
      $(CODEGEN_SRCS) $(PKG_SRCS)
HDRS = src/common.h src/lexer.h src/ast.h src/parser.h src/codegen.h \
      src/rtpath.h \
      src/codegen/internal.h src/codegen/liveness.h src/codegen/mir.h \
      src/codegen/pkg_net/pkg_net.h \
      src/codegen/pkg_time/pkg_time.h src/codegen/pkg_json/pkg_json.h \
      src/codegen/pkg_proc/pkg_proc.h
RT_SRCS = runtime/sl_core.c runtime/sl_gc.c runtime/sl_containers.c \
         runtime/sl_sched.c runtime/sl_pool.c runtime/sl_time.c \
         runtime/sl_net.c runtime/sl_tls.c runtime/sl_json.c \
         runtime/sl_proc.c

slangc: $(SRCS) $(HDRS) $(RT_SRCS)
	$(CC) $(CFLAGS) -o slangc $(SRCS)

tests/runtime/test_gc: tests/runtime/test_gc.c $(RT_SRCS)
	$(CC) -std=c11 -O2 -Wall -Wno-unused-function -I runtime \
		tests/runtime/test_gc.c -lpthread -o tests/runtime/test_gc

.PHONY: test clean

test: slangc tests/runtime/test_gc
	./tests/runtime/test_gc
	./slangc examples/hello/main.sl --run
	./slangc examples/fib/main.sl --run
	./slangc examples/pkgdemo/main.sl --run
	sh tests/run_tests.sh

clean:
	rm -f slangc hello main fib bytes ints lists fail_narrow fail_index \
		tests/runtime/test_gc
