# Thunderstorm Collector Makefile
# Default target shows menu
.DEFAULT_GOAL := help

ALL_TARGETS := $(shell go tool dist list)
BLACKLIST_OS := android ios
FILTERED_TARGETS := $(filter-out $(addsuffix /%,$(BLACKLIST_OS)),$(ALL_TARGETS))

# Build configuration
BUILD_ENV = GOOS=$(GOOS) GOARCH=$(GOARCH) CGO_ENABLED=0
LDFLAGS_RELEASE = -w -s

# Detect current platform
CURRENT_OS := $(shell go env GOOS)
CURRENT_ARCH := $(shell go env GOARCH)
CURRENT_PLATFORM := $(CURRENT_ARCH)-$(CURRENT_OS)

.PHONY: help
help: ## Show this help menu
	@echo "Thunderstorm Collector - Build Options"
	@echo "======================================"
	@echo ""
	@echo "Available targets:"
	@echo "  make build          - Build for current platform ($(CURRENT_PLATFORM))"
	@echo "  make build-all      - Build binaries for all supported platforms"
	@echo "  make release        - Build for all platforms and create distribution packages with config files"
	@echo "  make clean          - Remove all build artifacts"
	@echo "  make test           - Run tests"
	@echo ""
	@echo "Platform-specific builds:"
	@echo "  make bin/<arch>-<os>-thunderstorm-collector[.exe]"
	@echo "  Example: make bin/amd64-linux-thunderstorm-collector"
	@echo ""
	@echo "Note: Distribution packages include the binary and config.yml file."
	@echo ""

.PHONY: build
build: bin/$(CURRENT_ARCH)-$(CURRENT_OS)-thunderstorm-collector$(if $(findstring windows,$(CURRENT_OS)),.exe,) ## Build for current platform

.PHONY: build-all
build-all: LDFLAGS = $(LDFLAGS_RELEASE)
build-all: $(patsubst %,bin/%-thunderstorm-collector$(if $(findstring windows,$(lastword $(subst /, ,%))),.exe,),$(subst /,-,$(FILTERED_TARGETS))) ## Build binaries for all supported platforms

.PHONY: release
release: build-all ## Build for all platforms and create distribution packages with config files
	@echo "Creating distribution packages with config files..."
	@rm -rf dist
	@mkdir -p dist
	@for target in $(FILTERED_TARGETS); do \
		arch=$$(echo $$target | cut -d'/' -f1); \
		os=$$(echo $$target | cut -d'/' -f2); \
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
			cd dist && tar -czf $$package_name.tar.gz $$package_name/ && cd ..; \
			if [ "$$os" = "windows" ]; then \
				cd dist && zip -r $$package_name.zip $$package_name/ && cd ..; \
			fi; \
			rm -rf $$package_dir; \
			echo "Created package: dist/$$package_name.tar.gz"; \
			if [ "$$os" = "windows" ]; then \
				echo "Created package: dist/$$package_name.zip"; \
			fi; \
		fi; \
	done
	@echo ""
	@echo "Distribution packages created in dist/ (includes binary + config.yml)"

.PHONY: clean
clean: ## Remove all build artifacts
	@echo "Cleaning build artifacts..."
	@rm -rf bin dist
	@echo "Clean complete."

.PHONY: test
test: ## Run tests
	go test -v -cover ./...

# Generate build rules for all platforms
$(foreach target, $(FILTERED_TARGETS), \
	$(eval arch := $(word 1, $(subst /, ,$(target)))) \
	$(eval os := $(word 2, $(subst /, ,$(target)))) \
	$(eval binary := bin/$(arch)-$(os)-thunderstorm-collector$(if $(findstring windows,$(os)),.exe,)) \
	$(eval $(binary): GOOS=$(os)) \
	$(eval $(binary): GOARCH=$(arch)) \
)

# Build rule for binaries - extract GOOS and GOARCH from target name
bin/%: $(wildcard *.go) $(wildcard */*.go)
	@mkdir -p bin
	@target=$(notdir $@); \
	arch=$${target%%-*}; \
	rest=$${target#*-}; \
	os=$${rest%%-*}; \
	echo "Building $$target for $$os/$$arch..."; \
	GOOS=$$os GOARCH=$$arch CGO_ENABLED=0 go build -o $@ -ldflags "$(LDFLAGS)" .; \
	echo "Built: $@"
