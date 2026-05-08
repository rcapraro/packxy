BIN := packxy
PKG := ./cmd/packxy

# packxy uses cgo (IOKit power-state notifications), so cross-arch builds
# need an explicit C compiler with the right -arch flag.
CGO := CGO_ENABLED=1
LDFLAGS := -trimpath -ldflags="-s -w"

.PHONY: build build-arm64 build-amd64 universal clean tidy run-help

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

clean:
	rm -f $(BIN)
	rm -rf dist/

tidy:
	go mod tidy

run-help: build
	./$(BIN) --help
