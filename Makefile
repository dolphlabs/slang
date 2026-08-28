CC     = cc
CFLAGS = -std=c11 -O2 -Wall -Wextra

# Core codegen engine (type inference, expr/stmt codegen, program
# orchestration) plus native.c, the fixed-signature dispatch every
# pkg_*/sigs.c table plugs into.
CODEGEN_SRCS = src/codegen/core.c src/codegen/infer.c src/codegen/expr.c \
              src/codegen/stmt.c src/codegen/native.c \
              src/codegen/runtime_core.c src/codegen/runtime_gc.c \
              src/codegen/runtime_sched.c src/codegen/runtime_pool.c \
              src/codegen/program.c \
              src/codegen/liveness.c

# Native packages: each lives entirely under its own
# src/codegen/pkg_<name>/ directory (signatures + embedded C
# runtime, or for json -- generic over a target type, so it doesn't
# fit the fixed-signature NatSig table -- its own dispatch module).
PKG_SRCS = src/codegen/pkg_time/sigs.c src/codegen/pkg_time/runtime.c \
          src/codegen/pkg_net/sigs.c src/codegen/pkg_net/runtime_net.c \
          src/codegen/pkg_net/runtime_tls.c \
          src/codegen/pkg_json/dispatch.c src/codegen/pkg_json/runtime.c \
          src/codegen/pkg_proc/sigs.c src/codegen/pkg_proc/runtime.c

SRCS = src/main.c src/loader.c src/lexer.c src/parser.c $(CODEGEN_SRCS) \
      $(PKG_SRCS)
HDRS = src/common.h src/lexer.h src/ast.h src/parser.h src/codegen.h \
      src/codegen/internal.h src/codegen/liveness.h \
      src/codegen/pkg_net/pkg_net.h \
      src/codegen/pkg_time/pkg_time.h src/codegen/pkg_json/pkg_json.h \
      src/codegen/pkg_proc/pkg_proc.h

slangc: $(SRCS) $(HDRS)
	$(CC) $(CFLAGS) -o slangc $(SRCS)

.PHONY: test clean

test: slangc
	./slangc examples/hello/main.sl --run
	./slangc examples/fib/main.sl --run
	./slangc examples/pkgdemo/main.sl --run
	sh tests/run_tests.sh

clean:
	rm -f slangc hello main fib bytes ints lists fail_narrow fail_index
