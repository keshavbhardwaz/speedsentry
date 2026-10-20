.PHONY: build universal run test check clean

build:
	bash ./scripts/build-app.sh

universal:
	bash ./scripts/build-app.sh --universal

run: build
	open dist/SpeedSentry.app

test:
	swift test --build-system native

check:
	for script in scripts/*.sh; do bash -n "$$script" || exit; done
	plutil -lint Resources/Info.plist
	swift test --build-system native

clean:
	swift package clean
	rm -rf dist
