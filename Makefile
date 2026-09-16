APP_NAME := QuotaBar
BUILD_DIR := .build
CONFIG ?= debug
PROVIDER ?= codex
BIN := $(BUILD_DIR)/$(CONFIG)/$(APP_NAME)
DEBUG_BIN := $(BUILD_DIR)/debug/$(APP_NAME)
LOG_SUBSYSTEM := com.quotabar.app

## App state checks use debug launch flags; core regressions run in QuotaBarTests.
VERIFIERS := \
	menu-command \
	provider-state \
	pricing-validation \
	menu-lifecycle \
	pricing-refresh \
	cost-chart-highlighting \
	quota-recovery \
	relative-time \
	quota-reset-label \
	refresh-row \
	pricing-sort \
	pricing-model-filter \
	report-export

.PHONY: build run probe probe-cost benchmark-cost benchmark-startup logs kill test app readme-assets clean

build:
	swift build -c $(CONFIG) --product $(APP_NAME)

## Build and launch in the foreground. Logs land in this terminal; Ctrl-C stops the app.
run: kill build
	$(BIN)

## Headless check that both providers still return usable data.
probe:
	swift build -c $(CONFIG) --product $(APP_NAME)Probe
	$(BUILD_DIR)/$(CONFIG)/$(APP_NAME)Probe

## Rescan local logs and print cost totals. May refresh model prices; no quota requests.
probe-cost:
	swift build -c $(CONFIG) --product $(APP_NAME)Probe
	$(BUILD_DIR)/$(CONFIG)/$(APP_NAME)Probe --cost-only

## Benchmark empty-database and incremental scans of live logs with fixed offline pricing.
benchmark-cost:
	swift build -c release --product $(APP_NAME)Probe
	$(BUILD_DIR)/release/$(APP_NAME)Probe --benchmark-cost --provider $(PROVIDER)

## Measure status-item construction without credentials, network requests, or log scans.
benchmark-startup:
	swift build -c debug --product $(APP_NAME)
	$(DEBUG_BIN) --benchmark-menu-startup

## Stream os.Logger output. Use this when the app was not started from a terminal.
logs:
	log stream --level debug --predicate 'subsystem == "$(LOG_SUBSYSTEM)"'

## Stop a running instance so `make run` never leaves two menu bar icons behind.
kill:
	@pkill -x $(APP_NAME) 2>/dev/null || true

## Re-render every image the README links to. Needs ffmpeg.
readme-assets:
	Scripts/readme_assets.sh

## Assemble a double-clickable QuotaBar.app under build/.
app:
	Scripts/package_app.sh

## No XCTest without Xcode, so the suite is a plain executable of assertions.
test:
	swift build -c $(CONFIG) --product $(APP_NAME)Tests
	$(BUILD_DIR)/$(CONFIG)/$(APP_NAME)Tests
	swift build -c debug --product $(APP_NAME)
	@for check in $(VERIFIERS); do \
		echo "$(DEBUG_BIN) --verify-$$check"; \
		$(DEBUG_BIN) --verify-$$check || exit 1; \
	done

clean:
	swift package clean
	rm -rf $(BUILD_DIR) build
