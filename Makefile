# Reed. `make` on its own lists the targets.
#
# `make device` needs a paired, unlocked iPhone with Developer Mode on;
# the signing team is in the project, so Xcode needn't be open.

BUNDLE_ID := town.versary.reed
DERIVED := build
MAC_APP := $(DERIVED)/Build/Products/Debug/Reed.app
DEVICE_APP := $(DERIVED)/Build/Products/Debug-iphoneos/Reed.app

# Paired phones, one identifier per line. devicectl lists simulators too,
# and suffixes each identifier with its kind, e.g. "<udid> (UDID)".
device_filter = Reality != 'simulated'$(if $(DEVICE), AND Name == '$(DEVICE)')
list_devices = xcrun devicectl list devices --hide-headers --hide-default-columns --filter "$(device_filter)"
device_ids = $(shell $(list_devices) --columns Identifier 2>/dev/null | awk '{print $$1}')
device_id = $(firstword $(device_ids))

.DEFAULT_GOAL := help
.PHONY: help mac test smoke ios device check-device device-build project clean

help: ## list targets
	@grep -hE '^[a-z-]+:.*##' $(MAKEFILE_LIST) | sed -E 's/:[^#]*## /\t/' | expand -t16

mac: ## build and open the Mac app
	xcodebuild -project Reed.xcodeproj -scheme Reed -configuration Debug \
	  -destination 'platform=macOS' -derivedDataPath $(DERIVED) build
	open $(MAC_APP)

test: ## unit tests
	swift test

smoke: ## end-to-end offline check against the built Mac app
	python3 scripts/smoke_test.py

ios: ## check it still compiles for iOS (no device or signing needed)
	xcodebuild -project Reed.xcodeproj -target Reed \
	  -sdk iphoneos -configuration Debug CODE_SIGNING_ALLOWED=NO build

device: check-device device-build ## build, install and launch on an attached iPhone (DEVICE="name" to pick one)
	xcrun devicectl device install app --device $(device_id) $(DEVICE_APP)
	xcrun devicectl device process launch --device $(device_id) $(BUNDLE_ID)

check-device:
	@test -n "$(device_id)" || { \
	  echo "No device found$(if $(DEVICE), named \"$(DEVICE)\")."; \
	  echo "Plug the phone in, unlock it, trust this Mac, and turn on Developer Mode."; \
	  exit 1; \
	}
	@test $(words $(device_ids)) -eq 1 || { \
	  echo "More than one device attached:"; \
	  $(list_devices) --columns Name | sed -E 's/^/  /'; \
	  echo "Pass one with: make device DEVICE=\"name\""; \
	  exit 1; \
	}

device-build:
	xcodebuild -project Reed.xcodeproj -scheme Reed -configuration Debug \
	  -destination 'generic/platform=iOS' -derivedDataPath $(DERIVED) \
	  -allowProvisioningUpdates build

project: ## regenerate Reed.xcodeproj after adding source or resource files
	python3 scripts/generate_project.py

clean: ## drop all build products
	rm -rf .build build
