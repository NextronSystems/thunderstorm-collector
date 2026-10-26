# Thunderstorm Collector - Root Makefile

.PHONY: help
help:
	@echo "Thunderstorm Collector - Release Build System"
	@echo "============================================="
	@echo ""
	@echo "Available targets:"
	@echo "  make release         - Build binary packages and individual script assets"
	@echo "  make release-binary  - Build binary packages"
	@echo "  make release-scripts - Copy individual script assets"
	@echo "  make release-sftp    - Build SFTP collector packages for Linux (needs the Go version in sftp/go.mod)"
	@echo "  make clean           - Remove all release artifacts"
	@echo "  make test            - Run tests"
	@echo "  make help            - Show this help menu"
	@echo ""
	@echo "Note: Use go/Makefile directly for more specific build options."
	@echo "      make release does not build the SFTP collector, so it also runs with Go 1.10."

# Define version if not provided by the environment
VERSION ?= $(shell git describe --tags --always --dirty)
VERSION := ${VERSION:refs/tags/%=%}
RELEASE_VERSION := $(patsubst v%,%,$(VERSION:refs/tags/%=%))

.PHONY: release
release: release-binary release-scripts
	@echo "Release artifacts placed in release/"

.PHONY: release-binary
release-binary:
	@mkdir -p release
	@echo "Building release ${VERSION}"
	@$(MAKE) --no-print-directory -C go release
	@for f in go/dist/thunderstorm-collector*; do \
		suffix=$${f##*thunderstorm-collector-}; \
		cp "$$f" "release/thunderstorm-collector-${RELEASE_VERSION}-$${suffix}" || exit 1; done
	@cp go/config.yml "release/config-${RELEASE_VERSION}.yml"

.PHONY: release-scripts
release-scripts:
	@mkdir -p release
	@echo "Building script release ${RELEASE_VERSION}"
	@find scripts \
		-path 'scripts/tests' -prune -o \
		-path '*/__pycache__' -prune -o \
		-type f \( -name 'thunderstorm-collector*.sh' -o \
			-name 'thunderstorm-collector*.py' -o -name 'thunderstorm-collector*.pl' -o \
			-name 'thunderstorm-collector*.ps1' -o -name 'thunderstorm-collector*.bat' \) -print | \
	while IFS= read -r f; do \
		base=$$(basename "$$f"); \
		ext=$${base##*.}; \
		stem=$${base%.$$ext}; \
		target="release/$${stem}-${RELEASE_VERSION}.$$ext"; \
		cp "$$f" "$$target" || exit 1; \
	done

# The SFTP collector needs a current Go version, unlike the Go collector's
# release build, so it has its own target instead of being part of release.
.PHONY: release-sftp
release-sftp:
	@mkdir -p release
	@echo "Building SFTP collector release ${RELEASE_VERSION}"
	@$(MAKE) --no-print-directory -C sftp release
	@for f in sftp/dist/thunderstorm-sftp-collector-*.tar.gz; do \
		suffix=$${f##*thunderstorm-sftp-collector-}; \
		cp "$$f" "release/thunderstorm-sftp-collector-${RELEASE_VERSION}-$${suffix}" || exit 1; done

.PHONY: clean
clean: ## Remove all release artifacts
	@echo "Cleaning release artifacts..."
	@rm -rf release
	@$(MAKE) --no-print-directory -C go clean
	@$(MAKE) --no-print-directory -C sftp clean
	@echo "Clean complete."

.PHONY: test
test:
	@$(MAKE) -C go test
