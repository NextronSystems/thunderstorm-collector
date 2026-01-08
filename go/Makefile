# Thunderstorm Collector - Go Build System

# Get all supported platforms and filter out unsupported ones
ALL_TARGETS := $(shell go tool dist list)
BLACKLIST_OS := android ios
FILTERED_TARGETS := $(filter-out $(addsuffix /%,$(BLACKLIST_OS)),$(ALL_TARGETS))

# Extract unique architectures and operating systems
ALLARCHS := $(sort $(foreach t,$(FILTERED_TARGETS),$(word 2,$(subst /, ,$(t)))))
ALLOS := $(sort $(foreach t,$(FILTERED_TARGETS),$(word 1,$(subst /, ,$(t)))))

# Build configuration
LDFLAGS_RELEASE = -w -s

# Detect current platform using consistent method
CURRENT_OS := $(shell go env GOOS)
CURRENT_ARCH := $(shell go env GOARCH)

# Default target: build for current platform
.DEFAULT_GOAL := build

# Generate targets for each arch/os combination (enables tab completion)
$(foreach arch,$(ALLARCHS), \
	$(foreach os,$(ALLOS), \
		$(eval bin/$(arch)-$(os)-%: GOARCH=$(arch)) \
		$(eval bin/$(arch)-$(os)-%: GOOS=$(os)) \
		$(eval .PHONY: $(os)/$(arch)) \
		$(eval $(os)/$(arch): bin/$(arch)-$(os)-thunderstorm-collector$(if $(findstring windows,$(os)),.exe,)) \
))

.PHONY: help
help: ## Show this help menu
	@echo "Thunderstorm Collector - Build System"
	@echo "======================================"
	@echo ""
	@echo "Available targets:"
	@echo "  make         - Build for current platform ($(CURRENT_ARCH)-$(CURRENT_OS))"
	@echo "  make all     - Build binaries for all supported platforms"
	@echo "  make release - Create distribution packages (binary + config) for all platforms"
	@echo "  make clean   - Remove all build artifacts"
	@echo "  make test    - Run tests"
	@echo "  make help    - Show this help menu"
	@echo ""
	@echo "  make <os>/<arch> - Build for specific platform (e.g., make linux/amd64)"
	@echo ""
	@echo "Note: Packages include only the binary and config.yml."
	@echo "      Scripts are standalone alternatives to the Go binary."

.PHONY: build
build: bin/$(CURRENT_ARCH)-$(CURRENT_OS)-thunderstorm-collector$(if $(findstring windows,$(CURRENT_OS)),.exe,) ## Build for current platform

.PHONY: all
all: LDFLAGS = $(LDFLAGS_RELEASE)
all: ## Build binaries for all supported platforms
	@echo "Building binaries for all platforms..."
	@$(MAKE) $(foreach target,$(FILTERED_TARGETS),$(shell \
		os=$$(echo $(target) | cut -d'/' -f1); \
		arch=$$(echo $(target) | cut -d'/' -f2); \
		if [ "$$os" = "windows" ]; then \
			echo "bin/$$arch-$$os-thunderstorm-collector.exe"; \
		else \
			echo "bin/$$arch-$$os-thunderstorm-collector"; \
		fi))

.PHONY: release
release: all ## Create distribution packages (binary + config) for all platforms
	@echo "Creating distribution packages..."
	@rm -rf dist
	@mkdir -p dist
	@for target in $(FILTERED_TARGETS); do \
		os=$$(echo $$target | cut -d'/' -f1); \
		arch=$$(echo $$target | cut -d'/' -f2); \
		binary=bin/$$arch-$$os-thunderstorm-collector; \
		if [ "$$os" = "windows" ]; then \
			binary=$$binary.exe; \
		fi; \
		if [ -f "$$binary" ]; then \
			package_name=thunderstorm-collector-$$arch-$$os; \
			package_dir=dist/$$package_name; \
			mkdir -p $$package_dir; \
			cp $$binary $$package_dir/; \
			cp config.yml $$package_dir/; \
			if [ "$$os" = "windows" ]; then \
				cd dist && zip -q -r $$package_name.zip $$package_name/ && cd ..; \
				echo "Created package: dist/$$package_name.zip"; \
			else \
				cd dist && tar -czf $$package_name.tar.gz $$package_name/ && cd ..; \
				echo "Created package: dist/$$package_name.tar.gz"; \
			fi; \
			rm -rf $$package_dir; \
		fi; \
	done
	@echo ""
	@echo "Distribution packages created in dist/"

.PHONY: clean
clean: ## Remove all build artifacts
	@echo "Cleaning build artifacts..."
	@rm -rf bin dist
	@echo "Clean complete."

.PHONY: test
test: ## Run tests
	go test -v -cover ./...

# Build rule for individual binaries
# Binary names are in arch-os format (e.g., amd64-linux-thunderstorm-collector)
BUILD_ENV = GOOS=$(GOOS) GOARCH=$(GOARCH) CGO_ENABLED=0

bin/%: $(wildcard *.go)
	@mkdir -p bin
	$(BUILD_ENV) go build -o $@ -ldflags "$(LDFLAGS_RELEASE)"