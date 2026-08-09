APP := VibeNotch.app
SWIFT ?= swift
SWIFT_FLAGS ?=

.PHONY: app run

app:
	$(SWIFT) build -c release $(SWIFT_FLAGS)
	rm -rf -- "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS"
	cp ".build/release/VibeNotch" "$(APP)/Contents/MacOS/VibeNotch"
	cp "Support/Info.plist" "$(APP)/Contents/Info.plist"
	codesign --force --deep -s - "$(APP)"

run: app
	open "$(APP)"
