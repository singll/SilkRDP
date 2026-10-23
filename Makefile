BINARY_DIR := bin
GO ?= go
GOOS ?= linux
GOARCH ?= amd64
GOFLAGS := -trimpath
LDFLAGS := -s -w

.PHONY: all build gateway agent test vet fmt check clean

all: build

build: gateway agent

gateway:
	@mkdir -p $(BINARY_DIR)
	CGO_ENABLED=0 GOOS=$(GOOS) GOARCH=$(GOARCH) $(GO) build $(GOFLAGS) -ldflags "$(LDFLAGS)" -o $(BINARY_DIR)/rdp-gateway ./cmd/rdp-gateway

agent:
	@mkdir -p $(BINARY_DIR)
	CGO_ENABLED=0 GOOS=$(GOOS) GOARCH=$(GOARCH) $(GO) build $(GOFLAGS) -ldflags "$(LDFLAGS)" -o $(BINARY_DIR)/rdp6-agent ./cmd/rdp6-agent

test:
	$(GO) test ./...

vet:
	$(GO) vet ./...

fmt:
	$(GO) fmt ./...

check: vet test

clean:
	rm -rf $(BINARY_DIR)
