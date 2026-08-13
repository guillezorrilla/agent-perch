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

# Distribution identity, NEVER guessed. `SIGN_ID` above falls back happily, which is right
# for a local build and catastrophic for a release: an "Apple Development" cert signs a DMG
# without complaint and then fails Gatekeeper on every Mac except this one, with "VibeNotch
# is damaged and can't be opened" — which reads as a corrupt download rather than a signing
# mistake, so nobody reports it (#74). Both of these are therefore required, not defaulted:
#
#   make dmg DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=vibenotch
#
# The notary profile is created once with:
#
#   xcrun notarytool store-credentials vibenotch --apple-id … --team-id … --password <app-specific>
DEVELOPER_ID ?=
NOTARY_PROFILE ?=

VERSION := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Support/Info.plist)
STAGE := dist/stage
DMG := dist/VibeNotch-$(VERSION).dmg

.PHONY: app run dmg

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

# A downloadable, notarized, drag-to-Applications DMG (#74).
#
# Built from a FRESH bundle under dist/, never from the in-place `$(APP)` above: that one
# carries this machine's development signature and its TCC grants, and re-signing it for
# release would revoke both locally for no reason. The two bundles are independent on
# purpose — `make dmg` must not disturb a working local install.
#
# ponytail: `hdiutil` and an /Applications symlink, no `create-dmg` dependency and no
# background image. A background needs an AppleScript pass to position the Finder window
# and set the icon coordinates; add it when the plain window actually reads as confusing.
dmg:
	@test -n "$(DEVELOPER_ID)" || { echo "error: DEVELOPER_ID is unset. A release must NOT fall back to the development cert — see the comment above this target."; exit 1; }
	@test -n "$(NOTARY_PROFILE)" || { echo "error: NOTARY_PROFILE is unset. A Developer ID signature alone still trips Gatekeeper; the build has to be notarized."; exit 1; }
	$(SWIFT) build -c release $(SWIFT_FLAGS)
	rm -rf "$(STAGE)"
	mkdir -p "$(STAGE)/$(APP)/Contents/MacOS"
	@# Empty, but not optional: codesign seals a resource envelope regardless, and
	@# `--verify --strict` then rejects the bundle with "code has no resources but signature
	@# indicates they must be present". Notarization applies the same strictness.
	mkdir -p "$(STAGE)/$(APP)/Contents/Resources"
	cp ".build/release/VibeNotch" "$(STAGE)/$(APP)/Contents/MacOS/VibeNotch"
	cp "Support/Info.plist" "$(STAGE)/$(APP)/Contents/Info.plist"
	codesign --force --options runtime --timestamp \
		--entitlements "Support/VibeNotch.entitlements" \
		-s "$(DEVELOPER_ID)" "$(STAGE)/$(APP)"
	codesign --verify --strict --verbose=2 "$(STAGE)/$(APP)"
	@# codesign PRINTS a parse error for a bad entitlements file and then exits 0, signing
	@# the bundle with no entitlements at all. Under the hardened runtime that ships an app
	@# which installs, opens, and silently types nothing — so the entitlement is read back
	@# off the signature rather than assumed. (An XML comment inside the <dict> is enough to
	@# trip AMFI's parser, which is why that file carries none.)
	@codesign -d --entitlements - "$(STAGE)/$(APP)" 2>&1 | grep -q "apple-events" \
		|| { echo "error: the apple-events entitlement is missing from the signature — every scripted jump and answer would fail silently."; exit 1; }
	ln -s /Applications "$(STAGE)/Applications"
	hdiutil create -volname VibeNotch -srcfolder "$(STAGE)" -ov -format UDZO "$(DMG)"
	codesign --force --timestamp -s "$(DEVELOPER_ID)" "$(DMG)"
	xcrun notarytool submit "$(DMG)" --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple "$(DMG)"
	@echo
	@echo "$(DMG) is signed, notarized and stapled."
	@echo "Verify it on a Mac that has NEVER run VibeNotch — quarantine is only set on downloaded"
	@echo "files, so a machine where it already ran proves nothing."
