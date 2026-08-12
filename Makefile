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

# The bundle is UPDATED IN PLACE, never deleted and recreated. macOS books TCC grants
# against the app bundle, so `rm -rf` on the .app threw away "access data from other apps"
# — the consent needed to read Warp's sqlite for tab-exact jump and answer — on every
# single build, re-prompting the user forever. Same class of bug as ad-hoc signing losing
# the Accessibility grant, which the SIGN_ID comment above already guards against.
#
# The executable is unlinked first rather than copied over: replacing a RUNNING Mach-O in
# place fails with ETXTBSY, and unlinking does not disturb the process already running it.
app:
	$(SWIFT) build -c release $(SWIFT_FLAGS)
	mkdir -p "$(APP)/Contents/MacOS"
	rm -f -- "$(APP)/Contents/MacOS/VibeNotch"
	cp ".build/release/VibeNotch" "$(APP)/Contents/MacOS/VibeNotch"
	cp "Support/Info.plist" "$(APP)/Contents/Info.plist"
	@echo "Signing with identity: $(SIGN_ID)"
	codesign --force -s "$(SIGN_ID)" "$(APP)"

run: app
	open "$(APP)"
