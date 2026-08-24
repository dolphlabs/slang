CC     = cc
CFLAGS = -std=c11 -O2 -Wall -Wextra

SRCS = src/main.c src/loader.c src/lexer.c src/parser.c src/codegen.c
HDRS = src/common.h src/lexer.h src/ast.h src/parser.h src/codegen.h

slangc: $(SRCS) $(HDRS)
	$(CC) $(CFLAGS) -o slangc $(SRCS)

.PHONY: test clean

test: slangc
	./slangc examples/hello/main.sl --run
	./slangc examples/fib/main.sl --run
	./slangc examples/pkgdemo/main.sl --run

clean:
	rm -f slangc hello main fib
