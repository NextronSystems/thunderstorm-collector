# Thunderstorm Collector - Root Makefile
# This is a convenience wrapper around go/Makefile

.PHONY: help
help:
	@echo "Thunderstorm Collector - Build System"
	@echo "======================================"
	@echo ""
	@echo "Available targets:"
	@echo "  make release - Build distribution packages (binary + config)"
	@echo "  make clean   - Remove all build artifacts"
	@echo "  make test    - Run tests"
	@echo ""
	@echo "Note: Scripts in scripts/ are standalone and not part of the build."
	@echo "      Use go/Makefile directly for more build options."

.PHONY: release
release:
	@make -C go release

.PHONY: clean
clean:
	@make -C go clean

.PHONY: test
test:
	@make -C go test

