# Thunderstorm Collector - Root Makefile
.DEFAULT_GOAL := help

# Define version if not provided by the environment
VERSION ?= $(shell git describe --tags --always --dirty)
VERSION := ${VERSION:refs/tags/%=%}

.PHONY: help
help: ## Show this help menu
	@echo "Thunderstorm Collector - Root Makefile"
	@echo "======================================="
	@echo ""
	@echo "Available targets:"
	@echo "  make release      - Create release packages (calls go/Makefile)"
	@echo "  make clean        - Clean all build artifacts"
	@echo ""
	@echo "For Go collector builds, see: cd go && make help"
	@echo ""

.PHONY: release
release: ## Create release packages with version
	@rm -rf release
	@mkdir -p release
	@echo "Building release ${VERSION}"
	@make -C go build-all
	@for f in go/bin/* scripts/thunderstorm-collector.* go/config.yml; do \
		if [ -f "$$f" ]; then \
			ext=$${f##*.}; \
			if [ "$$ext" = "$$f" ]; then ext=''; else ext=".$$ext"; fi ; \
			cp "$$f" "release/$$(basename $${f%$$ext})-${VERSION:v%=%}$${ext}"; \
		fi; \
	done
	@echo "Release packages created in release/"

.PHONY: clean
clean: ## Clean all build artifacts
	@rm -rf release
	@make -C go clean
	@echo "All build artifacts cleaned."
