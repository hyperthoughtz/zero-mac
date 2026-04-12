# Zero

A minimal macOS proxy client built on [mihomo](https://github.com/MetaCubeX/mihomo), compiled from source.

**Zero** = self-compiled mihomo core + [metacubexd](https://github.com/MetaCubeX/metacubexd) web UI + native macOS menu bar control.

## Why

Eliminate supply-chain risk. All binaries are compiled from source on your machine.

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
- **TUN Mode** — toggle virtual network adapter (needs admin)
- **Set Subscription** — paste your proxy subscription URL
- **Open Web UI** — proxy selection, connections, logs, rules
- **Open Config** — edit `~/.config/mihomo/config.yaml`
- **Quit Zero** — stops mihomo and cleans up system proxy

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
/usr/local/bin/mihomo              self-compiled binary
/Applications/Zero.app             menu bar app
~/.config/mihomo/config.yaml       configuration
~/.config/mihomo/ui/               metacubexd web UI
/usr/local/var/log/mihomo.log      log (auto-rotated, 5MB max)
```

## License

MIT
