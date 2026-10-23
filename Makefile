PREFIX ?= /usr/local

.PHONY: build release test install app clean

build:
	swift build

release:
	swift build -c release

test:
	swift test

install: release
	install -d $(PREFIX)/bin
	install .build/release/camtool $(PREFIX)/bin/camtool

app:
	scripts/bundle-app.sh

clean:
	rm -rf .build build
