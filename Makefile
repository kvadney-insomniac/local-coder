# Developer entry points for the harness itself. `make check` is what CI runs.

SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

.PHONY: help deps lint test smoke dashes check

help:
	@echo "make deps    install the Python packages the harness needs"
	@echo "make lint    shellcheck every script (errors fail; warnings are listed)"
	@echo "make test    run the unit tests in tests/unit/"
	@echo "make smoke   run one tiny queue end to end with a fake claude CLI"
	@echo "make dashes  fail if any tracked file contains an em or en dash"
	@echo "make check   lint + test + smoke + dashes (what CI runs)"

deps:
	python3 -m pip install -r requirements-dev.txt
	bash scripts/check-deps.sh --no-claude

lint:
	shellcheck --version >/dev/null
	shellcheck -S error scripts/*.sh tests/*.sh tests/unit/*.sh tests/smoke/*.sh tests/fake-bin/claude
	shellcheck -S warning tests/*.sh tests/unit/*.sh tests/smoke/*.sh tests/fake-bin/claude scripts/check-deps.sh
	@echo "lint: ok"

test:
	bash tests/run-tests.sh

smoke:
	bash tests/smoke/run-smoke.sh

dashes:
	python3 tests/check-dashes.py

check: lint test smoke dashes
