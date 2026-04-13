# Zero

A minimal macOS proxy client built on [mihomo](https://github.com/MetaCubeX/mihomo), compiled from source.

**Zero** = self-compiled mihomo core + [metacubexd](https://github.com/MetaCubeX/metacubexd) web UI + native macOS menu bar control.

## Why

Eliminate supply-chain risk. All binaries are compiled from source on your machine.

## Architecture

```
launchd (root) → mihomo daemon (always running, TUN capable)
Zero.app (user) → REST API (127.0.0.1:9090) → mihomo
```

- mihomo runs as a system daemon via launchd — starts at boot, auto-restarts on crash
- Zero.app is a lightweight menu bar controller — no root privileges needed at runtime
- Admin password is only required once during installation

## Requirements

- macOS 13+
- [Go](https://go.dev/) 1.20+ (`brew install go`)
- Xcode Command Line Tools (`xcode-select --install`)

## Quick Start

```bash
git clone https://github.com/hyperthoughtz/zero-mac.git
cd zero-mac
make install
```

Then open **Zero** from Applications or Spotlight.

## Usage

Zero lives in the menu bar:

- **▲** = mihomo running, **△** = stopped
- **System Proxy** — toggle HTTP/SOCKS proxy for all network services
- **TUN Mode** — toggle virtual network adapter (no password needed)
- **Set Subscription** — paste your proxy subscription URL
- **Open Web UI** — auto-login to metacubexd dashboard
- **Open Config** — edit `~/.config/mihomo/config.yaml`
- **Quit Zero** — menu bar app exits; mihomo daemon keeps running

## Build

| Command | Description |
|---------|-------------|
| `make install` | Build + install everything |
| `make pkg` | Build `.pkg` installer |
| `make uninstall` | Remove (keeps config) |
| `make clean` | Remove build artifacts |

## Update

Edit `MIHOMO_TAG` in `Makefile`, then `make clean && make install`.

## Layout

```
/usr/local/bin/mihomo                    self-compiled binary
/Applications/Zero.app                   menu bar app
~/.config/mihomo/config.yaml             configuration
~/.config/mihomo/ui/                     metacubexd web UI
/usr/local/var/log/mihomo.log            log
/Library/LaunchDaemons/com.zero.mihomo.plist   daemon config
```

## License

MIT
