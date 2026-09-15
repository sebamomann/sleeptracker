# The front door: lint, test, duplication and build for the iOS app.
#
# The Swift tools are Homebrew binaries invoked directly. jscpd is the one Node tool, run
# through npx, because it is the lightest copy-paste detector that handles Swift at all.

SWIFTLINT_VERSION := 0.65.1
JSCPD_VERSION     := 4
XCODE_PROJECT     := ios/SleepTracker.xcodeproj
BUILD_LOG         := build/xcodebuild.log
TEST_LOG          := build/xcodebuild-test.log
UITEST_LOG        := build/xcodebuild-uitest.log

# The first available iPhone simulator, by UDID. Looked up because Xcode updates rename the
# devices; a UDID rather than a name because with two runtimes installed a bare name resolves
# to the newest OS, which may not have a device of that name at all.
SIMULATOR = $(shell xcrun simctl list devices available | grep -m1 iPhone | grep -oE '[0-9A-F-]{36}')

.DEFAULT_GOAL := help
.PHONY: help tools project lint fix test uitest dupes build check clean

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

# Regenerated when the spec changes or a file is added or removed — a directory's mtime
# moves on add/remove but not on edit, which is exactly the distinction wanted. Depending on
# the .swift files themselves would regenerate on every keystroke, and `build: project`
# regenerated unconditionally, throwing away everything Xcode had resolved for the project
# including the provisioning it works out when a device connects.
SWIFT_DIRS := $(shell find ios/SleepTracker ios/SleepTrackerTests ios/SleepTrackerUITests -type d)

$(XCODE_PROJECT): ios/project.yml $(SWIFT_DIRS)
	cd ios && xcodegen generate

lint: ## SwiftLint (strict) and SwiftFormat, check only
	swiftlint lint --strict --quiet
	swiftformat --lint .

fix: ## Autocorrect the mechanical half
	swiftlint --fix --quiet
	swiftformat .

test: $(XCODE_PROJECT) ## Swift tests on the simulator — gate, calibration, timeline, vocabulary
	@mkdir -p build
	@test -n "$(SIMULATOR)" || { echo "no iPhone simulator — see AGENTS.md before downloading"; exit 1; }
	@xcodebuild test -project $(XCODE_PROJECT) -scheme SleepTracker \
		-destination 'platform=iOS Simulator,id=$(SIMULATOR)' \
		-derivedDataPath build/xcode-test CODE_SIGNING_ALLOWED=NO \
		-only-testing:SleepTrackerTests > $(TEST_LOG) 2>&1 \
		|| { grep -E '✘|error:' $(TEST_LOG) | head -30; echo "see $(TEST_LOG)"; exit 1; }
	@grep -E 'Test run with' $(TEST_LOG)

# Separate from `check`: each test relaunches the app, so the suite takes a few minutes where
# the unit tests take seconds. Run it after touching a screen.
uitest: $(XCODE_PROJECT) ## End-to-end UI tests in the simulator, against fixture nights (minutes)
	@mkdir -p build
	@test -n "$(SIMULATOR)" || { echo "no iPhone simulator — see AGENTS.md before downloading"; exit 1; }
	@xcodebuild test -project $(XCODE_PROJECT) -scheme SleepTracker \
		-destination 'platform=iOS Simulator,id=$(SIMULATOR)' \
		-derivedDataPath build/xcode-test CODE_SIGNING_ALLOWED=NO \
		-only-testing:SleepTrackerUITests > $(UITEST_LOG) 2>&1 \
		|| { grep -E 'error:|failed \(' $(UITEST_LOG) | head -30; echo "see $(UITEST_LOG)"; exit 1; }
	@grep -cE "Test Case .* passed" $(UITEST_LOG) | xargs -I{} echo "{} UI tests passed"

dupes: ## Copy-paste detection across the app and its tests
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
