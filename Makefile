.PHONY: build check lint test

lint test build: check

check:
	./scripts/check_project.sh
