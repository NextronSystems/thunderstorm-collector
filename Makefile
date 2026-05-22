# Thunderstorm Collector - Root Makefile

.PHONY: help
help:
	@echo "Thunderstorm Collector - Release Build System"
	@echo "============================================="
	@echo ""
	@echo "Available targets:"
	@echo "  make release         - Build binary packages and script package"
	@echo "  make release-binary  - Build binary packages"
	@echo "  make release-scripts - Build script package"
	@echo "  make clean           - Remove all release artifacts"
	@echo "  make test            - Run tests"
	@echo "  make help            - Show this help menu"
	@echo ""
	@echo "Note: Use go/Makefile directly for more specific build options."

# Define version if not provided by the environment
VERSION ?= $(shell git describe --tags --always --dirty)
VERSION := ${VERSION:refs/tags/%=%}
RELEASE_VERSION := ${VERSION:v%=%}
SCRIPT_RELEASE_DIR := release/thunderstorm-collector-scripts-${RELEASE_VERSION}

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
		cp "$$f" "release/thunderstorm-collector-${RELEASE_VERSION}-$${suffix}"; done

.PHONY: release-scripts
release-scripts:
	@mkdir -p "${SCRIPT_RELEASE_DIR}"
	@echo "Building script release ${RELEASE_VERSION}"
	@find scripts \
		-path 'scripts/tests' -prune -o \
		-path '*/__pycache__' -prune -o \
		-type f \( -name 'README.md' -o -name 'thunderstorm-collector*' \) -print | \
	while IFS= read -r f; do \
		target="${SCRIPT_RELEASE_DIR}/$$f"; \
		mkdir -p "$$(dirname "$$target")"; \
		cp "$$f" "$$target"; \
	done
	@if command -v zip >/dev/null 2>&1; then \
		(cd release && zip -qr "thunderstorm-collector-scripts-${RELEASE_VERSION}.zip" "thunderstorm-collector-scripts-${RELEASE_VERSION}"); \
	fi

.PHONY: clean
clean: ## Remove all release artifacts
	@echo "Cleaning release artifacts..."
	@rm -rf release
	@$(MAKE) --no-print-directory -C go clean
	@echo "Clean complete."

.PHONY: test
test:
	@$(MAKE) -C go test
