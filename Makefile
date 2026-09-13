# The front door for both halves of the repo: a Swift app and a JS/Node web spike.
#
# Neither half's package manager belongs in charge of the other, so neither is. npm runs the
# Node tests because that is its job; the Swift tools are Homebrew binaries invoked directly.

SWIFTLINT_VERSION := 0.65.1
JSCPD_VERSION     := 4
XCODE_PROJECT     := ios/SleepTracker.xcodeproj
BUILD_LOG         := build/xcodebuild.log

.DEFAULT_GOAL := help
.PHONY: help tools project lint fix test dupes build check clean

help: ## Show this list
	@grep -hE '^[a-z][a-z-]*:.*##' $(MAKEFILE_LIST) \
		| sed -e 's/:[^#]*##/|/' \
		| awk -F'|' '{ printf "  \033[1m%-10s\033[0m %s\n", $$1, $$2 }'

tools: ## Install the Swift toolchain, and warn if it drifts from CI
	brew bundle --file=Brewfile
	@installed=$$(swiftlint version); \
	if [ "$$installed" != "$(SWIFTLINT_VERSION)" ]; then \
		echo "warning: swiftlint $$installed locally, CI pins $(SWIFTLINT_VERSION)."; \
		echo "         Update SWIFTLINT_VERSION here and the image tag in the Jenkinsfile,"; \
		echo "         or a rule added upstream fails the build with no code change."; \
	fi

project: ## Regenerate the Xcode project from ios/project.yml
	cd ios && xcodegen generate

# Regenerated only when the spec actually changes. `build: project` rebuilt it on every
# single build, which threw away everything Xcode had resolved for the project — including
# the provisioning it works out when a device connects.
$(XCODE_PROJECT): ios/project.yml
	cd ios && xcodegen generate

lint: ## SwiftLint (strict) and SwiftFormat, check only
	swiftlint lint --strict --quiet
	swiftformat --lint .

fix: ## Autocorrect the mechanical half
	swiftlint --fix --quiet
	swiftformat .

test: ## The analysis suite — the gate's rules live in public/analysis.js
	npm test

dupes: ## Copy-paste detection, across Swift and JS in one pass
	npx --yes jscpd@$(JSCPD_VERSION) . --config .jscpd.json --reporters console

build: $(XCODE_PROJECT) ## Compile the iOS target, unsigned
	@mkdir -p build
	@xcodebuild -project $(XCODE_PROJECT) -scheme SleepTracker -configuration Debug \
		-destination 'generic/platform=iOS' -derivedDataPath build/xcode \
		CODE_SIGNING_ALLOWED=NO build > $(BUILD_LOG) 2>&1 \
		|| { grep -E 'error:' $(BUILD_LOG) | head -20; echo "see $(BUILD_LOG)"; exit 1; }
	@echo "build: ok"

check: lint test dupes build ## Everything — run before finishing a task

clean: ## Remove build output and reports
	rm -rf build reports
