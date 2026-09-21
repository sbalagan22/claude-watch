# claude_watch
#
# make build      release build of the app (universal)
# make debug      debug build
# make test       unit tests + hook bridge + installer tests
# make run        build and launch
# make install-hooks   merge the hook config into ~/.claude/settings.json
# make idle-cpu   measure idle CPU of a running instance

PROJECT  := ClaudeWatch.xcodeproj
SCHEME   := ClaudeWatch
CONFIG   := Release
DERIVED  := build
APP      := $(DERIVED)/Build/Products/$(CONFIG)/ClaudeWatch.app

.PHONY: all build debug test test-hooks test-installer test-unit run clean generate install-hooks uninstall-hooks idle-cpu lint

all: build

generate: $(PROJECT)

$(PROJECT): project.yml
	@command -v xcodegen >/dev/null || { echo "xcodegen not found: brew install xcodegen"; exit 1; }
	xcodegen generate

build: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) \
		-derivedDataPath $(DERIVED) ONLY_ACTIVE_ARCH=NO build | \
		grep -E '(error|warning|BUILD)' || true
	@test -d "$(APP)" && echo "built: $(APP)" || { echo "build failed"; exit 1; }
	@lipo -archs "$(APP)/Contents/MacOS/ClaudeWatch" 2>/dev/null | \
		sed 's/^/architectures: /' || true

debug: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
		-derivedDataPath $(DERIVED) build | grep -E '(error|warning|BUILD)' || true

test: test-hooks test-installer test-unit

test-hooks:
	@echo "== hook bridge =="
	@bash Scripts/test-hooks.sh

test-installer:
	@echo "== installer =="
	@python3 Scripts/test-installer.py

test-unit: generate
	@echo "== unit tests =="
	@xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
		-derivedDataPath $(DERIVED) test 2>&1 | \
		grep -E '(Test Case|error:|\*\* TEST|Executed)' || true

run: build
	@pkill -x ClaudeWatch 2>/dev/null || true
	open "$(APP)"

install-hooks:
	python3 Scripts/install-hooks.py

uninstall-hooks:
	python3 Scripts/install-hooks.py uninstall

idle-cpu:
	@bash Scripts/measure-idle-cpu.sh

clean:
	rm -rf $(DERIVED) $(PROJECT)
