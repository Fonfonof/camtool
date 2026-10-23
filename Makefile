PREFIX ?= /usr/local

.PHONY: build release test install app install-app clean

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

install-app: app
	rm -rf /Applications/CamTool.app
	ditto build/CamTool.app /Applications/CamTool.app

clean:
	rm -rf .build build
