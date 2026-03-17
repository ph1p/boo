.PHONY: build run clean

build:
	swift build

run: build
	.build/debug/Exterm

release:
	swift build -c release

clean:
	swift package clean
	rm -rf .build
