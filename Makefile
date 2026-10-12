.PHONY: help doctor test init models link release clean

help:
	@sed -n 's/^##//p' Makefile

## doctor: check pi, token, gateway, gh, and web tools
doctor:
	./bin/localcode doctor

## test: run the smoke suite in a throwaway config dir
test:
	./test/smoke.sh

## init: seed the default config dir
init:
	./bin/localcode init

## models: list models the gateway advertises
models:
	./bin/localcode models

## link: install the localcode command with npm
link:
	npm link

## release: dry run of a release, V=<version>, add ARGS=--publish to publish
release:
	./scripts/release.sh $(V) $(ARGS)

## clean: remove the local npm link
clean:
	npm unlink localcode 2>/dev/null || true
