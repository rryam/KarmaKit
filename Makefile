.PHONY: setup build test format lint readiness clean

setup:
	./scripts/setup.sh

build:
	swift build --build-tests

test:
	swift test

test-coverage:
	./scripts/run-tests-with-coverage.sh

format:
	xcrun swift-format format --recursive --in-place Package.swift Sources Tests

lint:
	xcrun swift-format lint --strict --recursive Package.swift Sources Tests
	swiftlint lint --strict

readiness:
	./scripts/agent-readiness.sh
	./scripts/validate-agents-md.sh

clean:
	swift package clean
	rm -rf .build-metrics .test-metrics coverage
