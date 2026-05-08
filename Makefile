BIN := packxy
APP := packxy.app
PKG := ./cmd/packxy
ICON_PNG := assets/icon.png

# packxy uses cgo (IOKit power-state notifications), so cross-arch builds
# need an explicit C compiler with the right -arch flag.
CGO := CGO_ENABLED=1
LDFLAGS := -trimpath -ldflags="-s -w"

# Version embedded in the .app's Info.plist. Defaults to "dev"; the release
# workflow overrides it with the tag name.
VERSION ?= dev

.PHONY: build build-arm64 build-amd64 universal app app-arm64 app-amd64 \
        app-universal icon clean tidy run-help

build:
	$(CGO) go build $(LDFLAGS) -o $(BIN) $(PKG)

build-arm64:
	$(CGO) GOOS=darwin GOARCH=arm64 CC="cc -arch arm64" \
		go build $(LDFLAGS) -o dist/$(BIN)-arm64 $(PKG)

build-amd64:
	$(CGO) GOOS=darwin GOARCH=amd64 CC="cc -arch x86_64" \
		go build $(LDFLAGS) -o dist/$(BIN)-amd64 $(PKG)

universal: build-arm64 build-amd64
	lipo -create -output dist/$(BIN) dist/$(BIN)-arm64 dist/$(BIN)-amd64
	@file dist/$(BIN)

# icon regenerates assets/icon.png from cmd/genicon. Idempotent — the
# generator overwrites the file each time.
icon:
	go run ./cmd/genicon

# bundle-app: helper macro invoked by the per-arch app targets. Builds the
# .app skeleton from a binary in $(BIN_PATH), an iconset, and the Info.plist
# template. Ad-hoc-signs the result so macOS treats it as a real bundle
# (notifications then pick up the bundle icon and identifier).
define bundle-app
	@command -v iconutil >/dev/null || { echo "iconutil not found (Xcode CLT required)"; exit 1; }
	@command -v sips >/dev/null || { echo "sips not found (macOS only)"; exit 1; }
	@test -f $(ICON_PNG) || { $(MAKE) icon; }
	rm -rf $(2)
	mkdir -p $(2)/Contents/MacOS $(2)/Contents/Resources
	# iconset: required sizes per Apple HIG (16, 32, 64, 128, 256, 512, 1024)
	# at 1x and 2x. iconutil consumes a .iconset directory and emits .icns.
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
	iconutil -c icns -o $(2)/Contents/Resources/AppIcon.icns build/AppIcon.iconset
	# Info.plist with version substitution.
	sed "s|__VERSION__|$(VERSION)|g" resources/Info.plist > $(2)/Contents/Info.plist
	cp $(1) $(2)/Contents/MacOS/$(BIN)
	chmod +x $(2)/Contents/MacOS/$(BIN)
	# Ad-hoc signature so macOS accepts the bundle as a real app (no
	# Developer ID required for local install). The notification system
	# treats unsigned .apps as untrusted and may fall back to the script
	# icon — ad-hoc signing is enough to dodge that.
	codesign --force --deep --sign - $(2)
	codesign --verify --deep --strict $(2) >/dev/null
	@echo "Built $(2) (version $(VERSION))"
endef

# app: build native-arch binary, wrap in packxy.app at the project root.
app: build
	$(call bundle-app,$(BIN),$(APP))

app-arm64: build-arm64
	$(call bundle-app,dist/$(BIN)-arm64,dist/$(APP)-arm64.app)

app-amd64: build-amd64
	$(call bundle-app,dist/$(BIN)-amd64,dist/$(APP)-amd64.app)

# app-universal: produce a single .app whose internal binary contains both
# arm64 and x86_64 slices. This is the artifact recommended for download.
app-universal: universal
	$(call bundle-app,dist/$(BIN),dist/$(APP))

clean:
	rm -f $(BIN)
	rm -rf $(APP) dist/ build/AppIcon.iconset

tidy:
	go mod tidy

run-help: build
	./$(BIN) --help
