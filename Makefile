APP_NAME := QuotaBar
BUILD_DIR := .build
CONFIG ?= debug
PROVIDER ?= codex
PREVIEW_STATE ?= loaded
SNAPSHOT_DIR ?= $(BUILD_DIR)/screenshots/card
SWIFT := Scripts/swift.sh
BIN := $(BUILD_DIR)/$(CONFIG)/$(APP_NAME)
DEBUG_BIN := $(BUILD_DIR)/debug/$(APP_NAME)
LOG_SUBSYSTEM := com.quotabar.app

.PHONY: build run preview card-snapshot probe probe-cost benchmark-cost benchmark-startup logs kill test app readme-assets clean

build:
	$(SWIFT) build -c $(CONFIG) --product $(APP_NAME)

## Build and launch in the foreground. Logs land in this terminal; Ctrl-C stops the app.
run: kill build
	$(BIN)

## Build and open the isolated sample interface without stopping the installed app.
preview:
	$(SWIFT) build -c debug --product $(APP_NAME)
	$(DEBUG_BIN) --preview-interface $(PREVIEW_STATE)

## Render offscreen card images from sample data into SNAPSHOT_DIR.
card-snapshot:
	$(SWIFT) build -c debug --product $(APP_NAME)
	$(DEBUG_BIN) --dump-card "$(SNAPSHOT_DIR)"
	@printf 'Card snapshots: %s\n' "$(SNAPSHOT_DIR)"

## Headless check that both providers still return usable data.
probe:
	$(SWIFT) build -c $(CONFIG) --product $(APP_NAME)Probe
	$(BUILD_DIR)/$(CONFIG)/$(APP_NAME)Probe

## Rescan local logs and print cost totals. No quota or pricing requests.
probe-cost:
	$(SWIFT) build -c $(CONFIG) --product $(APP_NAME)Probe
	$(BUILD_DIR)/$(CONFIG)/$(APP_NAME)Probe --cost-only

## Benchmark empty-database and incremental scans of live logs with fixed offline pricing.
benchmark-cost:
	$(SWIFT) build -c release --product $(APP_NAME)Probe
	$(BUILD_DIR)/release/$(APP_NAME)Probe --benchmark-cost --provider $(PROVIDER)

## Measure status-item construction without credentials, network requests, or log scans.
benchmark-startup:
	$(SWIFT) build -c debug --product $(APP_NAME)
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

## Core and app regressions use a plain executable of assertions. Always a debug build: the
## suite imports the app with @testable, which needs a module compiled for testing.
test:
	$(SWIFT) build -c debug --product $(APP_NAME)Tests
	$(BUILD_DIR)/debug/$(APP_NAME)Tests

clean:
	$(SWIFT) package clean
	rm -rf $(BUILD_DIR) build
