ALLARCHS := 386 amd64 arm arm64 ppc64 ppc64le mips mipsle mips64 mips64le
ALLOS := android darwin dragonfly freebsd linux netbsd openbsd plan9 solaris windows
DEFAULT_TARGETS := amd64-darwin amd64-linux arm64-linux 386-linux amd64-windows 386-windows arm-windows amd64-netbsd amd64-openbsd amd64-freebsd amd64-solaris

$(foreach arch, $(ALLARCHS), \
	$(foreach os, $(ALLOS), \
		$(eval bin/$(arch)-$(os)-%: GOARCH=$(arch)) \
		$(eval bin/$(arch)-$(os)-%: GOOS=$(os)) \
))

BUILD_ENV=GOOS=$(GOOS) GOARCH=$(GOARCH) CGO_ENABLED=0

all: $(foreach target, $(DEFAULT_TARGETS), bin/$(target)-thunderstorm-collector)

bin/%-thunderstorm-collector: $(wildcard *.go)
	$(BUILD_ENV) go build -v -o $@ -ldflags "-w -s"

.PHONY: all