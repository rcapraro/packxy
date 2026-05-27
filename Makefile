ICON_PNG := assets/icon.png

# Packxy is a pure Swift macOS app (since the Go implementation was
# retired). We build via SPM rather than xcodebuild because the repo
# is meant to stay buildable from Command Line Tools alone — no full
# Xcode required. The executable produced by `swift build` is then
# wrapped into a proper .app bundle (Info.plist + AppIcon + ad-hoc
# codesign) via the same sips/iconutil pipeline the Go bundle used.

SWIFT_PKG := Packxy
SWIFT_APP := dist/Packxy.app
SWIFT_BIN_NAME := Packxy
SWIFT_BUILD_DIR := $(SWIFT_PKG)/.build/release

# Version embedded in the .app's Info.plist. Defaults to "dev"; the
# release workflow overrides it with the tag name.
VERSION ?= dev

.PHONY: build clean run

build:
	swift build --package-path $(SWIFT_PKG) -c release
	@command -v iconutil >/dev/null || { echo "iconutil not found (Xcode CLT required)"; exit 1; }
	@command -v sips >/dev/null || { echo "sips not found (macOS only)"; exit 1; }
	@test -f $(ICON_PNG) || { echo "missing $(ICON_PNG)"; exit 1; }
	rm -rf $(SWIFT_APP)
	mkdir -p $(SWIFT_APP)/Contents/MacOS $(SWIFT_APP)/Contents/Resources
	rm -rf build/AppIcon.iconset
	mkdir -p build/AppIcon.iconset
	sips -z 16 16     $(ICON_PNG) --out build/AppIcon.iconset/icon_16x16.png         >/dev/null
	sips -z 32 32     $(ICON_PNG) --out build/AppIcon.iconset/icon_16x16@2x.png      >/dev/null
	sips -z 32 32     $(ICON_PNG) --out build/AppIcon.iconset/icon_32x32.png         >/dev/null
	sips -z 64 64     $(ICON_PNG) --out build/AppIcon.iconset/icon_32x32@2x.png      >/dev/null
	sips -z 128 128   $(ICON_PNG) --out build/AppIcon.iconset/icon_128x128.png       >/dev/null
	sips -z 256 256   $(ICON_PNG) --out build/AppIcon.iconset/icon_128x128@2x.png    >/dev/null
	sips -z 256 256   $(ICON_PNG) --out build/AppIcon.iconset/icon_256x256.png       >/dev/null
	sips -z 512 512   $(ICON_PNG) --out build/AppIcon.iconset/icon_256x256@2x.png    >/dev/null
	sips -z 512 512   $(ICON_PNG) --out build/AppIcon.iconset/icon_512x512.png       >/dev/null
	cp $(ICON_PNG)                build/AppIcon.iconset/icon_512x512@2x.png
	iconutil -c icns -o $(SWIFT_APP)/Contents/Resources/AppIcon.icns build/AppIcon.iconset
	sed "s|__VERSION__|$(VERSION)|g" $(SWIFT_PKG)/Info.plist > $(SWIFT_APP)/Contents/Info.plist
	cp $(SWIFT_BUILD_DIR)/$(SWIFT_BIN_NAME) $(SWIFT_APP)/Contents/MacOS/$(SWIFT_BIN_NAME)
	chmod +x $(SWIFT_APP)/Contents/MacOS/$(SWIFT_BIN_NAME)
	# Ad-hoc signature so macOS treats the bundle as a real app
	# (no Developer ID required for local install). The notification
	# system treats unsigned .apps as untrusted and won't surface the
	# bundle icon — ad-hoc signing is enough to dodge that.
	codesign --force --deep --sign - $(SWIFT_APP)
	codesign --verify --deep --strict $(SWIFT_APP) >/dev/null
	@echo "Built $(SWIFT_APP) (version $(VERSION))"

clean:
	rm -rf $(SWIFT_APP) dist/ build/AppIcon.iconset $(SWIFT_PKG)/.build

run: build
	open $(SWIFT_APP)
