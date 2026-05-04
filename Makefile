BIN := packxy
PKG := ./cmd/packxy

.PHONY: build build-arm64 build-amd64 universal clean tidy run-help

build:
	go build -trimpath -ldflags="-s -w" -o $(BIN) $(PKG)

build-arm64:
	GOOS=darwin GOARCH=arm64 go build -trimpath -ldflags="-s -w" -o dist/$(BIN)-arm64 $(PKG)

build-amd64:
	GOOS=darwin GOARCH=amd64 go build -trimpath -ldflags="-s -w" -o dist/$(BIN)-amd64 $(PKG)

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
