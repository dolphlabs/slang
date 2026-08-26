CC     = cc
CFLAGS = -std=c11 -O2 -Wall -Wextra

CODEGEN_SRCS = src/codegen/core.c src/codegen/infer.c src/codegen/expr.c \
              src/codegen/stmt.c src/codegen/native.c src/codegen/json.c \
              src/codegen/runtime_core.c src/codegen/runtime_time.c \
              src/codegen/runtime_net.c src/codegen/runtime_tls.c \
              src/codegen/runtime_json.c src/codegen/program.c
SRCS = src/main.c src/loader.c src/lexer.c src/parser.c $(CODEGEN_SRCS)
HDRS = src/common.h src/lexer.h src/ast.h src/parser.h src/codegen.h \
      src/codegen/internal.h

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
