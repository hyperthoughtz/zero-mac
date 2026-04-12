.PHONY: build build-app download-ui install pkg uninstall clean help

MIHOMO_REPO := https://github.com/MetaCubeX/mihomo.git
MIHOMO_TAG  := v1.19.9
UI_URL      := https://github.com/MetaCubeX/metacubexd/releases/latest/download/compressed-dist.tgz
VERSION     := 1.0.0
APP_NAME    := Zero.app

# --- Build mihomo from source ---

build: _build/mihomo

_build/mihomo:
	@echo "==> Cloning mihomo $(MIHOMO_TAG)..."
	@mkdir -p _build
	@if [ ! -d _build/src ]; then \
		git clone --depth 1 --branch $(MIHOMO_TAG) $(MIHOMO_REPO) _build/src; \
	fi
	@echo "==> Compiling mihomo..."
	@cd _build/src && CGO_ENABLED=0 go build -tags with_gvisor \
		-trimpath \
		-ldflags '-X "github.com/metacubex/mihomo/constant.Version=$(MIHOMO_TAG)" -w -s -buildid=' \
		-o ../mihomo
	@echo "==> Done: _build/mihomo"
	@file _build/mihomo

# --- Build Zero.app ---

build-app: _build/$(APP_NAME)

_build/$(APP_NAME):
	@echo "==> Compiling Zero.app..."
	@mkdir -p _build/$(APP_NAME)/Contents/MacOS _build/$(APP_NAME)/Contents/Resources
	@swiftc -O -o _build/$(APP_NAME)/Contents/MacOS/Zero app/ZeroApp.swift -framework Cocoa
	@cp app/Info.plist _build/$(APP_NAME)/Contents/
	@swift app/GenerateIcon.swift _build/$(APP_NAME)/Contents/Resources/Zero.icns 2>/dev/null
	@echo "==> Done: _build/$(APP_NAME)"

# --- Download metacubexd web UI ---

download-ui: _build/ui/index.html

_build/ui/index.html:
	@echo "==> Downloading metacubexd..."
	@mkdir -p _build
	@curl -sL -o _build/ui.tgz $(UI_URL)
	@mkdir -p _build/ui && tar xzf _build/ui.tgz -C _build/ui
	@echo "==> Done: _build/ui/"

# --- Install (dev machine) ---

install: build build-app download-ui
	@echo "==> Installing..."
	@sudo mkdir -p /usr/local/bin /usr/local/var/log
	@sudo cp _build/mihomo /usr/local/bin/mihomo && sudo chmod 755 /usr/local/bin/mihomo
	@rm -rf /Applications/$(APP_NAME) && cp -r _build/$(APP_NAME) /Applications/$(APP_NAME)
	@mkdir -p $(HOME)/.config/mihomo
	@if [ ! -f $(HOME)/.config/mihomo/config.yaml ]; then \
		SECRET=$$(openssl rand -hex 16); \
		sed "s|\$${SECRET}|$$SECRET|g" config/config.yaml.template > $(HOME)/.config/mihomo/config.yaml; \
		echo "    Created config.yaml (secret: $$SECRET)"; \
	fi
	@rm -rf $(HOME)/.config/mihomo/ui && cp -r _build/ui $(HOME)/.config/mihomo/ui
	@echo ""
	@echo "==> Installed! Open Zero from Applications or Spotlight."

# --- Package .pkg for distribution ---

pkg: build build-app download-ui
	@echo "==> Packaging..."
	@rm -rf _build/pkg-root
	@mkdir -p _build/pkg-root/usr/local/bin \
	          _build/pkg-root/usr/local/share/mihomo/ui \
	          _build/pkg-root/Applications
	@cp _build/mihomo _build/pkg-root/usr/local/bin/mihomo
	@chmod 755 _build/pkg-root/usr/local/bin/mihomo
	@cp -r _build/$(APP_NAME) _build/pkg-root/Applications/$(APP_NAME)
	@cp config/config.yaml.template _build/pkg-root/usr/local/share/mihomo/
	@cp -r _build/ui/* _build/pkg-root/usr/local/share/mihomo/ui/
	@pkgbuild --root _build/pkg-root --identifier com.zero.proxy \
		--version $(VERSION) --scripts pkg --install-location / \
		_build/Zero-$(VERSION).pkg
	@echo "==> Done: _build/Zero-$(VERSION).pkg"
	@ls -lh _build/Zero-$(VERSION).pkg

# --- Uninstall ---

uninstall:
	@echo "==> Uninstalling..."
	@pkill -f Zero.app 2>/dev/null || true
	@sudo rm -f /usr/local/bin/mihomo
	@rm -rf /Applications/$(APP_NAME)
	@echo "==> Done. Config kept at ~/.config/mihomo"

# --- Util ---

clean:
	@rm -rf _build

help:
	@echo "Usage:"
	@echo "  make build       Compile mihomo from source"
	@echo "  make build-app   Compile Zero.app"
	@echo "  make install     Build + install (dev machine)"
	@echo "  make pkg         Build .pkg installer"
	@echo "  make uninstall   Remove (keeps config)"
	@echo "  make clean       Remove build artifacts"
