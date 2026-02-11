# Thunderstorm Collector - Root Makefile

.PHONY: help
help:
	@echo "Thunderstorm Collector - Release Build System"
	@echo "============================================="
	@echo ""
	@echo "Available targets:"
	@echo "  make release - Build distribution packages (binary + config) and arrange scripts"
	@echo "  make clean   - Remove all release artifacts"
	@echo "  make test    - Run tests"
	@echo "  make help    - Show this help menu"
	@echo ""
	@echo "Note: Use go/Makefile directly for more specific build options."

# Define version if not provided by the environment
VERSION ?= $(shell git describe --tags --always --dirty)
VERSION := ${VERSION:refs/tags/%=%}

.PHONY: release
release:
	@mkdir -p release
	@echo "Building release ${VERSION}"
	@make -C go release
	@for f in go/dist/thunderstorm-collector*; do \
		suffix=$${f##*thunderstorm-collector-}; \
		cp "$$f" "release/thunderstorm-collector-${VERSION:v%=%}-$${suffix}"; done
	@for f in scripts/thunderstorm-collector.* go/config.yml; do \
		ext=$${f##*.}; if [ "$$ext" = "$$f" ]; then ext=''; else ext=".$$ext"; fi ; \
		cp "$$f" "release/$$(basename $${f%$$ext})-${VERSION:v%=%}$${ext}"; done
	@echo ""
	@echo "Release artifacts placed in release/"

.PHONY: clean
clean: ## Remove all release artifacts
	@echo "Cleaning release artifacts..."
	@rm -rf release
	@make --no-print-directory -C go clean
	@echo "Clean complete."

.PHONY: test
test:
	@make -C go test
