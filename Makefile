# Define version if not provided by the environment
VERSION ?= $(shell git describe --tags --always --dirty)
VERSION := ${VERSION:refs/tags/%=%}

release:
	@rm -rf release
	@mkdir -p release
	@echo "Building release ${VERSION}"
	make -C go all
	for f in go/bin/* scripts/thunderstorm-collector.* go/config.yml; do \
		ext=$${f##*.}; if [ "$$ext" = "$$f" ]; then ext=''; else ext=".$$ext"; fi ; \
		cp "$$f" "release/$$(basename $${f%$$ext})-${VERSION:v%=%}$${ext}"; done

clean:
	rm -rf release
	make -C go clean

.PHONY: release clean