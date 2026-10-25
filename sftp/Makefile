# Thunderstorm SFTP Collector - Build System
# Needs the Go version in go.mod or newer. Release packages cover the Linux
# systems the collector runs on: the Thunderstorm host or a system between the
# source and Thunderstorm, never the source itself.

NAME := thunderstorm-sftp-collector
RELEASE_TARGETS := linux/amd64 linux/arm64
LDFLAGS_RELEASE := -s -w

.DEFAULT_GOAL := build

# Build for the current platform.
.PHONY: build
build:
	go build -o bin/$(NAME) .

# One binary and one package per release target. Binaries are named
# <arch>-<os>-thunderstorm-sftp-collector, as the Go collector names its own.
define release_target
bin/$(2)-$(1)-$(NAME): FORCE
	@mkdir -p bin
	CGO_ENABLED=0 GOOS=$(1) GOARCH=$(2) go build -trimpath -ldflags "$(LDFLAGS_RELEASE)" -o $$@ .

dist/$(NAME)-$(2)-$(1).tar.gz: bin/$(2)-$(1)-$(NAME) README.md
	@rm -rf dist/$(NAME)-$(2)-$(1)
	@mkdir -p dist/$(NAME)-$(2)-$(1)
	cp bin/$(2)-$(1)-$(NAME) README.md dist/$(NAME)-$(2)-$(1)/
	tar -C dist -czf $$@ $(NAME)-$(2)-$(1)
	@rm -rf dist/$(NAME)-$(2)-$(1)

release: dist/$(NAME)-$(2)-$(1).tar.gz
endef
$(foreach target,$(RELEASE_TARGETS),$(eval $(call release_target,$(word 1,$(subst /, ,$(target))),$(word 2,$(subst /, ,$(target))))))

# Create the release packages (binary and README) for RELEASE_TARGETS; the
# prerequisites are set above.
.PHONY: release
release:

.PHONY: test
test:
	go vet ./...
	go test -race -count=1 ./...

.PHONY: clean
clean:
	rm -rf bin dist

FORCE:
