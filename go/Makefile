ALL_TARGETS := $(shell go tool dist list)
DEFAULT_TARGETS := amd64-darwin amd64-linux 386-linux 386-windows amd64-netbsd amd64-openbsd amd64-freebsd amd64-solaris

ALLARCHS := $(sort $(subst /,,$(notdir $(ALL_TARGETS))))
ALLOS := $(sort $(subst /,,$(dir $(ALL_TARGETS))))

all: $(filter-out darwin/arm%,$(filter-out android%,$(ALL_TARGETS)))
default: $(foreach target, $(DEFAULT_TARGETS), bin/$(target)-thunderstorm-collector)

$(foreach arch, $(ALLARCHS), \
	$(foreach os, $(ALLOS), \
		$(eval bin/$(arch)-$(os)-%: GOARCH=$(arch)) \
		$(eval bin/$(arch)-$(os)-%: GOOS=$(os)) \
		$(eval .PHONY: $(os)/$(arch)) \
		$(eval $(os)/$(arch): bin/$(arch)-$(os)-thunderstorm-collector$(if $(findstring windows,$(os)),.exe,)) \
))

BUILD_ENV=GOOS=$(GOOS) GOARCH=$(GOARCH) CGO_ENABLED=0

bin/%: $(wildcard *.go)
	$(BUILD_ENV) go build -v -o $@ -ldflags "-w -s"

.PHONY: all default