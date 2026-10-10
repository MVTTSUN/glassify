# Entry points; the real work is in scripts/. IPA defaults to the first file in ipa/.
IPA ?= $(firstword $(wildcard ipa/*.ipa))

# What goes on the phone is the mod alone. FLEX is the inspector `make trees` reads the screens
# through, so it rides along only when it is asked for: make install FLEX=1. (A make target cannot
# take --flex; make would read that as an option of its own.)
FLEX ?= 0
FLEX_ARG := $(if $(filter 0,$(FLEX)),--no-flex,)

# A local install is renamed and re-iconed so it is told apart from the released app on the home
# screen.
DEV_NAME ?= Glassify.dev
DEV_ICON ?= icons/Glassify.png

.PHONY: build release deb install quick trees session log flags
build:    ## FLEX + glass IPA into out/
	./scripts/pipeline.sh $(IPA)
# The release is named and iconed as Glassify on the home screen; the bundle id stays Spotify's
# (scripts/pipeline.sh says why).
APP_NAME ?= Glassify
APP_ICON ?= icons/Glassify.png
release:  ## glass only, no FLEX
	./scripts/pipeline.sh $(IPA) --no-flex --name "$(APP_NAME)" --icon "$(APP_ICON)"
# The tweak alone, for injecting into a clean Spotify IPA with Feather (or any signer that takes a .deb). The flag
# table comes from the IPA in ipa/ the first time; without one, the last table extracted is used. What the IPA build
# changes in the app itself (the Live Activity, Music Haptics in the background, the alternate icons, the home screen
# widget's App Group shim) cannot ride in a .deb, and Mod Settings says what is missing.
deb:      ## the tweak's .deb alone into out/, for Feather
	@test -f tweak/Sources/Shared/Flags/SGFlagList.m || { test -n "$(IPA)" && ./scripts/extract-flags.py $(IPA); } || \
	  { echo "no flag table: put a decrypted Spotify IPA in ipa/ once, or run make flags" >&2; exit 1; }
	env -u MAKELEVEL gmake -C tweak clean package FINALPACKAGE=1
	@mkdir -p out && cp "$$(ls -t tweak/packages/*.deb | head -1)" "out/Glassify-$$(cat version.txt).deb" && echo "==> out/Glassify-$$(cat version.txt).deb"
install:  ## build, sign with your certificate, push to the phone on USB (FLEX=1 to take FLEX too)
	./scripts/pipeline.sh $(IPA) --install $(FLEX_ARG) --name "$(DEV_NAME)" --icon "$(DEV_ICON)" -o out/Glassify.dev.ipa
quick:    ## a tweak-only change into the app the last build made: rebuild, sign, install in seconds
	./scripts/quick.sh
trees:    ## record per-screen view trees into trees/ (needs a FLEX build on the phone)
	./scripts/record-trees.py
session:  ## record clean trees screen by screen into trees/clean/, Enter per snapshot, n for the next screen (SCREENS="playlist artist" for some)
	./scripts/record-session.py $(SCREENS)
log:     ## stream the tweak's log lines from the phone
	./scripts/dump-log.sh
flags:    ## regenerate tweak/Sources/Shared/Flags/SGFlagList.m, Spotify's remote-config flags, from the IPA
	./scripts/extract-flags.py $(IPA)
