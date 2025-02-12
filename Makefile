release:
	@rm -rf release
	@mkdir -p release
	make -C go all
	zip release/thunderstorm-collectors.zip go/bin/* scripts/thunderstorm-collector.*

clean:
	rm -r release
	make -C go clean

.PHONY: release clean