# Face ID — build, test and package.
#
# Kept as a thin wrapper over `xcodebuild` rather than a second build system: the
# project already builds from Xcode, and anything this file invented would be one
# more thing to keep in sync with `project.pbxproj`.
#
# ---------------------------------------------------------------------------
# Sandbox workaround
#
# `SANDBOX_FIX=1` (the default) adds two flags that are only needed when the build
# host cannot apply `sandbox-exec` — which is the case for this project's own
# development environment. They are:
#
#   ENABLE_USER_SCRIPT_SANDBOXING=NO               — for the CoreML build task
#   OTHER_SWIFT_FLAGS=-Xfrontend -disable-sandbox  — for the Swift macro plugin server
#
# Neither is written into the project; both are build-time only. On a host that can
# apply sandbox-exec normally, use `make build SANDBOX_FIX=0` to build with full
# compiler isolation. See README.md → "Build environment notes".
# ---------------------------------------------------------------------------

PROJECT  := Face ID.xcodeproj
SCHEME   := Face ID
CONFIG   ?= Debug
DERIVED  := build/DerivedData
DEST     := platform=macOS,arch=arm64
APP      := $(DERIVED)/Build/Products/$(CONFIG)/Face ID.app

# Unsigned: the repo ships with no DEVELOPMENT_TEAM (see README), so a plain
# `xcodebuild` would stop at "requires a development team".
UNSIGNED := CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""

SANDBOX_FIX ?= 1
ifeq ($(SANDBOX_FIX),1)
  SANDBOX_FLAGS := ENABLE_USER_SCRIPT_SANDBOXING=NO OTHER_SWIFT_FLAGS="-Xfrontend -disable-sandbox"
else
  SANDBOX_FLAGS :=
endif

XCB := xcodebuild -project "$(PROJECT)" -scheme "$(SCHEME)" \
       -destination '$(DEST)' -derivedDataPath $(DERIVED)

.PHONY: all build test run release dmg clean help

all: build

## Build the app (Debug unless CONFIG=Release).
build:
	$(XCB) -configuration $(CONFIG) $(UNSIGNED) $(SANDBOX_FLAGS) build
	@echo "→ $(APP)"

## Run the test suite. A clean DerivedData is REQUIRED — see README.
test:
	rm -rf $(DERIVED)
	$(XCB) -configuration Debug $(UNSIGNED) $(SANDBOX_FLAGS) test

## Build and launch. Only useful with a signed build: an unsigned bundle can't
## hold its Keychain access group, so the app won't get past setup.
run: build
	open "$(APP)"

## Release build + DMG. Pass TEAM_ID=XXXXXXXXXX to sign for real distribution.
release:
	./scripts/package-dmg.sh

dmg: release

clean:
	rm -rf build

help:
	@echo "make build          Debug build (CONFIG=Release for release)"
	@echo "make test           Unit tests (wipes DerivedData first)"
	@echo "make run            Build and launch"
	@echo "make release        Release build + DMG into build/dist/"
	@echo "make clean          Remove build/"
	@echo ""
	@echo "Variables:"
	@echo "  CONFIG=Release        configuration for 'build'"
	@echo "  TEAM_ID=XXXXXXXXXX    development team, for a signed release"
	@echo "  SANDBOX_FIX=0         drop the sandbox workaround flags"
