APP := VibeNotch.app
SWIFT ?= swift
SWIFT_FLAGS ?=

# A STABLE signing identity keeps the Accessibility grant (needed for Warp tab focus)
# across rebuilds — ad-hoc (`-`) changes every build and macOS revokes the grant each
# time. Prefer an existing "Apple Development" identity, else a self-signed "VibeNotch"
# cert if present, else fall back to ad-hoc. Override with `make app SIGN_ID="..."`.
SIGN_ID ?= $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $$2; exit}')
ifeq ($(strip $(SIGN_ID)),)
SIGN_ID := $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/VibeNotch/ {print $$2; exit}')
endif
ifeq ($(strip $(SIGN_ID)),)
SIGN_ID := -
endif

.PHONY: app run

app:
	$(SWIFT) build -c release $(SWIFT_FLAGS)
	rm -rf -- "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS"
	cp ".build/release/VibeNotch" "$(APP)/Contents/MacOS/VibeNotch"
	cp "Support/Info.plist" "$(APP)/Contents/Info.plist"
	@echo "Signing with identity: $(SIGN_ID)"
	codesign --force --deep -s "$(SIGN_ID)" "$(APP)"

run: app
	open "$(APP)"
