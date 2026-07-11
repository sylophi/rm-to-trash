PREFIX ?= /usr/local
CC      = clang
CFLAGS  = -O2 -Wall -Wextra -fobjc-arc
LDFLAGS = -framework Foundation

rmt: rmt.m
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $<

# Fat binary (Apple Silicon + Intel)
universal: rmt.m
	$(CC) $(CFLAGS) $(LDFLAGS) -arch arm64 -arch x86_64 -o rmt $<

install: rmt
	install -d $(PREFIX)/bin
	install -m 755 rmt $(PREFIX)/bin/rmt

test: rmt
	./test.sh

clean:
	rm -f rmt

.PHONY: universal install test clean
