# Define version if not provided by the environment
VERSION ?= $(shell git describe --tags --always --dirty)
VERSION := ${VERSION:refs/tags/%=%}

.PHONY: help
help:
	@echo "Thunderstorm Collector - Release Build System"
	@echo "=============================================="
	@echo ""
	@echo "Available targets:"
	@echo "  make release        - Build all distribution packages"
	@echo "  make release-binary - Build binary packages only (binary + config)"
	@echo "  make release-scripts - Build scripts package only"
	@echo "  make clean          - Remove all build artifacts"
	@echo ""

.PHONY: release
release: release-binary release-scripts
	@echo ""
	@echo "✓ Release packages created successfully!"
	@echo "  Binary packages: go/dist/*.tar.gz, go/dist/*.zip"
	@echo "  Scripts package: release/thunderstorm-collector-scripts.zip"

.PHONY: release-binary
release-binary:
	@echo "Building binary packages (binary + config)..."
	@make -C go release

.PHONY: release-scripts
release-scripts:
	@echo "Building scripts package..."
	@rm -rf release
	@mkdir -p release
	@cd scripts && zip -q -r ../release/thunderstorm-collector-scripts.zip \
		thunderstorm-collector.sh \
		thunderstorm-collector.ps1 \
		thunderstorm-collector.py \
		thunderstorm-collector.pl \
		thunderstorm-collector.bat
	@echo "✓ Scripts package created: release/thunderstorm-collector-scripts.zip"

.PHONY: clean
clean:
	@echo "Cleaning all build artifacts..."
	@rm -rf release
	@make -C go clean
	@echo "✓ Clean complete"

.PHONY: test
test:
	@make -C go test

