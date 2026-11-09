VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
LDFLAGS  = -s -w -X main.version=$(VERSION)

.PHONY: build test lint tidy run-sandbox clean

build:
	CGO_ENABLED=0 go build -trimpath -ldflags '$(LDFLAGS)' -o bin/pgvigil ./cmd/pgvigil

test:
	go test ./...

lint:
	golangci-lint run ./...

tidy:
	go mod tidy

clean:
	rm -rf bin

# frontend: rebuild internal/web/dist from web/ (needs Node; the output is committed)
.PHONY: web
web:
	cd web && npm ci && npm run build
