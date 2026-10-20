# Release build, install app + CLI, relaunch
install:
    ./scripts/install.sh

# Run the menu bar app from a debug build
dev:
    swift run HarbourApp

test:
    swift test
