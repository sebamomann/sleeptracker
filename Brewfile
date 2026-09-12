# The Swift toolchain this project expects. `make tools` installs it.
#
# These are native Swift binaries, not Node packages — npm was only ever the task runner,
# and the Makefile is now the front door for both halves of the repo.
#
# Homebrew does not pin versions in a Brewfile. The versions CI uses are recorded in the
# Makefile (SWIFTLINT_VERSION) and `make tools` checks the local one matches, because the
# failure worth preventing is "passes locally, fails in CI" after an unrelated brew upgrade.
brew "swiftlint"    # 0.65.1 — smells, complexity, length, naming
brew "swiftformat"  # 0.63.0 — formatting only
brew "xcodegen"     # 2.46.0 — generates SleepTracker.xcodeproj from ios/project.yml
