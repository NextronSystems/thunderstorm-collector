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
# Note: .tar.gz by default, .zip (and .exe for contained binaries) on Windows.
$(foreach target,$(FILTERED_TARGETS), \
	$(eval arch := $(word 2,$(subst /, ,$(target)))) \
	$(eval os := $(word 1,$(subst /, ,$(target)))) \
	$(eval bin/$(arch)-$(os)-%: GOARCH=$(arch)) \
	$(eval bin/$(arch)-$(os)-%: GOOS=$(os)) \
	$(eval .PHONY: $(os)/$(arch)) \
	$(eval TMP_FILE := $(arch)-$(os)-thunderstorm-collector$(if $(findstring windows,$(os)),.exe,)) \
	$(eval $(os)/$(arch): bin/$(TMP_FILE)) \
	$(eval all: bin/$(TMP_FILE)) \
	$(eval TMP_PACK := thunderstorm-collector-$(arch)-$(os)$(if $(findstring windows,$(os)),.zip,.tar.gz)) \
	$(eval dist/$(TMP_PACK): bin/$(TMP_FILE)) \
	$(eval release: dist/$(TMP_PACK)) \
)

# Build rule for individual binaries
# Binary names are in arch-os format (e.g., amd64-linux-thunderstorm-collector)
BUILD_ENV = GOOS=$(GOOS) GOARCH=$(GOARCH) CGO_ENABLED=0

bin/%: $(wildcard *.go)
	@mkdir -p bin
	@echo "$(OUTINDENT)Building for $(GOOS)/$(GOARCH): $@"
	@echo -n "$(OUTINDENT)  "
	$(BUILD_ENV) go build -o $@ -ldflags "$(LDFLAGS)"

dist/%:
	@mkdir -p dist
	@pack_path="$@"; \
	pack_file=$${pack_path#dist/}; \
	ext=$${pack_file#*.}; \
	pack_name=$${pack_file%%.*}; \
	arch_os=$${pack_name#thunderstorm-collector-}; \
	binary=bin/$$arch_os-thunderstorm-collector; \
	archive_cmd="tar -czf"; \
	if [ "$$ext" = "zip" ]; then \
		binary=$$binary.exe; \
		archive_cmd="zip -q -r"; \
	fi; \
	pack_dir=dist/$$pack_name; \
	mkdir -p $$pack_dir && \
	cp $$binary $$pack_dir/ && \
	cp config.yml $$pack_dir/ && \
	cd dist && $$archive_cmd "$$pack_file" "$$pack_name/" && cd .. && \
	echo "$(OUTINDENT)Created package: dist/$$pack_file" && \
	rm -rf $$pack_dir

# Indent output for nested make calls (e.g., when calling from top-level directory)
OUTINDENT := $(shell for i in `seq ${MAKELEVEL}`; do echo -n "  "; done)

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
	@echo ""
	@echo "Note on format:"
	@echo "      Packages are gzipped tar archives (.tar.gz) by default,"
	@echo "      except for Windows, which uses zip (.zip)."
	@echo "      On Windows, binaries have an additional .exe suffix."
 
# Build for current platform
.PHONY: build
build: bin/$(CURRENT_ARCH)-$(CURRENT_OS)-thunderstorm-collector$(if $(findstring windows,$(CURRENT_OS)),.exe,)
## Enforce rebuild for current platform to pick up release flags
bin/$(CURRENT_ARCH)-$(CURRENT_OS)-thunderstorm-collector$(if $(findstring windows,$(CURRENT_OS)),.exe,): FORCE

FORCE:

# Build binaries for all supported platforms (prerequisites are set above)
.PHONY: all
all: LDFLAGS = $(LDFLAGS_RELEASE)

# Create distribution packages (binary + config) for all platforms (prerequisites are set above)
.PHONY: release
release: LDFLAGS = $(LDFLAGS_RELEASE)

.PHONY: clean
clean: ## Remove all build artifacts
	@echo "$(OUTINDENT)Cleaning build artifacts..."
	@rm -rf bin dist
	@echo "$(OUTINDENT)Clean complete."

.PHONY: test
test: ## Run tests
	go test -v -cover ./...
