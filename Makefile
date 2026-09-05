SWIFTC = swift
BIN = .build/release/coroner
PREFIX ?= /usr/local

.PHONY: build test release install clean demo selfcheck

build:
	$(SWIFTC) build

test:
	$(SWIFTC) test

release:
	$(SWIFTC) build -c release

install: release
	install -d $(DESTDIR)$(PREFIX)/bin
	install $(BIN) $(DESTDIR)$(PREFIX)/bin/coroner

selfcheck: release
	@$(CURDIR)/Examples/selfcheck/run.sh $(CURDIR)

demo: release
	@rm -rf /tmp/coroner-demo && mkdir -p /tmp/coroner-demo
	@cd /tmp/coroner-demo && $(CURDIR)/$(BIN) ingest $(CURDIR)/Examples/demo/* && \
		($(CURDIR)/$(BIN) new-since 141; echo "exit=$$? (1 = gate would block this release)") && \
		$(CURDIR)/$(BIN) top 3

clean:
	$(SWIFTC) package clean
	rm -rf .build
