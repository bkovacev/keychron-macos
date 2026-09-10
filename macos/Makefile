# Keychron K10 Pro battery — macOS menu bar agent
#
#   make            build the binary
#   make app        wrap it in K10ProBattery.app (menu bar only)
#   make install    install that into ~/Applications
#   make xcode      build via Xcode instead, which also gets you the
#                   Control Center controls, and install it
#   make login      start whatever is installed at login (LaunchAgent)
#   make unlogin    stop starting it at login
#   make once       print one reading as JSON
#   make uninstall  remove app + LaunchAgent

BIN       := .build/release/K10ProBattery
APP       := K10ProBattery.app
APPDIR    := $(HOME)/Applications
AGENT_ID  := io.smartowl.k10pro-battery
AGENT     := $(HOME)/Library/LaunchAgents/$(AGENT_ID).plist

LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

.PHONY: all build app install xcode login unlogin once run uninstall clean

all: build

build:
	swift build -c release

$(BIN): build

app: $(BIN)
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(BIN) $(APP)/Contents/MacOS/K10ProBattery
	printf '%s\n' \
	  '<?xml version="1.0" encoding="UTF-8"?>' \
	  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	  '<plist version="1.0"><dict>' \
	  '  <key>CFBundleName</key><string>K10ProBattery</string>' \
	  '  <key>CFBundleDisplayName</key><string>K10 Pro Battery</string>' \
	  '  <key>CFBundleIdentifier</key><string>$(AGENT_ID)</string>' \
	  '  <key>CFBundleExecutable</key><string>K10ProBattery</string>' \
	  '  <key>CFBundlePackageType</key><string>APPL</string>' \
	  '  <key>CFBundleShortVersionString</key><string>1.0</string>' \
	  '  <key>LSMinimumSystemVersion</key><string>13.0</string>' \
	  '  <key>LSUIElement</key><true/>' \
	  '</dict></plist>' > $(APP)/Contents/Info.plist
	# Ad-hoc signature so macOS remembers the Input Monitoring grant across rebuilds.
	codesign --force --sign - $(APP)
	@echo "built $(APP)"

install: app
	mkdir -p $(APPDIR)
	rm -rf $(APPDIR)/$(APP)
	cp -R $(APP) $(APPDIR)/
	@echo "installed $(APPDIR)/$(APP)"

# The Control Center controls live in a WidgetKit app extension, which needs a
# real Xcode build: the extension point has to be nested under NSExtension in
# the appex Info.plist, and a hand-assembled bundle is not registered by
# pluginkit. This target generates the project, builds it and installs it.
xcode:
	python3 ControlCenter/generate-project.py
	xcodebuild -project ControlCenter/K10ProControls.xcodeproj \
	           -scheme K10ProBattery -configuration Release \
	           -derivedDataPath ControlCenter/build build
	-launchctl bootout gui/$(shell id -u)/$(AGENT_ID) 2>/dev/null
	mkdir -p $(APPDIR)
	rm -rf $(APPDIR)/$(APP)
	cp -R ControlCenter/build/Build/Products/Release/$(APP) $(APPDIR)/
	$(LSREGISTER) -f -R -trusted $(APPDIR)/$(APP)
	@echo "installed $(APPDIR)/$(APP) with Control Center controls"
	@echo "run 'make login' to start it at login, then add the controls in"
	@echo "Control Center (click Edit Controls at the bottom)"

# Installs a LaunchAgent for whatever is already in ~/Applications, so it works
# after either 'make install' or 'make xcode'.
login:
	@test -d $(APPDIR)/$(APP) || { echo "run 'make install' or 'make xcode' first"; exit 1; }
	mkdir -p $(dir $(AGENT))
	printf '%s\n' \
	  '<?xml version="1.0" encoding="UTF-8"?>' \
	  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	  '<plist version="1.0"><dict>' \
	  '  <key>Label</key><string>$(AGENT_ID)</string>' \
	  '  <key>ProgramArguments</key>' \
	  '  <array><string>$(APPDIR)/$(APP)/Contents/MacOS/K10ProBattery</string></array>' \
	  '  <key>RunAtLoad</key><true/>' \
	  '  <key>KeepAlive</key><true/>' \
	  '</dict></plist>' > $(AGENT)
	-launchctl bootout gui/$(shell id -u)/$(AGENT_ID) 2>/dev/null
	launchctl bootstrap gui/$(shell id -u) $(AGENT)
	@echo "will start at login"

unlogin:
	-launchctl bootout gui/$(shell id -u)/$(AGENT_ID) 2>/dev/null
	rm -f $(AGENT)
	@echo "no longer starting at login"

once: $(BIN)
	@$(BIN) --once

run: $(BIN)
	$(BIN)

uninstall: unlogin
	rm -rf $(APPDIR)/$(APP)
	@echo "removed"

clean:
	rm -rf .build $(APP) ControlCenter/build
