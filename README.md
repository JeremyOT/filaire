# Filaire

[![Platform](https://img.shields.io/badge/platform-iPadOS%20%7C%20iOS-blue.svg)](https://apple.com)
[![Swift](https://img.shields.io/badge/swift-6.0-orange.svg)](https://swift.org)
[![Rust](https://img.shields.io/badge/rust-edition%202021-red.svg)](https://rust-lang.org)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE.md)

**Filaire** is a native SSH terminal and tmux client for iPad and iPhone, built on [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) and [Citadel](https://github.com/orlandos-nl/Citadel) (SwiftNIO SSH).

---

## Features

### Connections & Security
* Face ID / Touch ID lock per host.
* Ed25519 and RSA keys generated on-device and stored in the iOS Keychain.
* SSH agent forwarding with biometric approval for each signing request, so private keys never leave the device.
* ProxyJump / bastion hosts.
* Local (`ssh -L`) and dynamic SOCKS5 (`ssh -D`) port forwarding.
* Host key verification with a manageable known-hosts list.
* Keep-alive and automatic reconnection when the network changes.

### tmux
* Attach to or create a tmux session on connect (named after your username by default), or run a custom command instead.
* Pull-down tmux control bar for windows 0–9, splits, pane zoom and navigation.
* Three-finger swipe to switch tmux windows.
* Configurable prefix key (`Ctrl-B`, `Ctrl-A`, `Ctrl-Z`, …), mirrored on the on-screen accessory bar.

### Multi-Window (iPadOS)
* One window per host, with Split View, Slide Over and Stage Manager support.
* Drag a host out of the list to open it in its own window.
* Window titles follow the remote shell (OSC 0/2).
* Home Screen quick actions for recently connected hosts.
* Tapping a notification opens the window of the host that sent it.

### Terminal & Input
* Hardware keyboard shortcuts and a customizable on-screen accessory bar.
* Mouse reporting, trackpad scrolling and pinch-to-zoom font size.
* Tappable links in terminal output (`https`, `http`, `file`, `ssh`, `git`).
* Configurable bell: visual flash, haptic, both, or off.
* Themes: Solarized Dark, Solarized Light, Dracula, Nord and Monokai.

---

## Companion CLI (`fil`)

`fil` is a single-binary Rust tool for your servers, found in [`tools/fil`](tools/fil/README.md). It talks to Filaire through terminal escape sequences, so it works inside tmux.

| Command | Action |
| :--- | :--- |
| `fil copy <file or text>` | Copy to the iOS clipboard (OSC 52) |
| `fil open <url>` | Open a link on the device (OSC 5100) |
| `fil preview <file>` | Show a file in Quick Look (OSC 5101) |
| `fil notify <message>` | Send a notification (OSC 777) |
| `eval $(fil agent)` | Use Filaire's forwarded biometric SSH agent |
| `fil status` | Check tmux, TTY and agent status |

---

## Keyboard Shortcuts

| Shortcut | Action |
| :--- | :--- |
| `Cmd + Shift + N` / `Cmd + Shift + W` | New / close window |
| `Cmd + T` / `Cmd + W` | New tmux window / close pane |
| `Cmd + N` / `Cmd + P` (or `Cmd + ]` / `Cmd + [`) | Next / previous tmux window |
| `Cmd + 1…9`, `Cmd + Opt + 0` | Jump to tmux window |
| `Cmd + D` / `Cmd + Shift + D` | Split vertically / horizontally |
| `Cmd + Opt + Arrow` | Move between panes |
| `Cmd + Shift + R` | Rename tmux window |
| `Cmd + Opt + C` | tmux copy mode |
| `Cmd + K` | Clear screen |
| `Cmd + +` / `Cmd + -` / `Cmd + 0` | Increase / decrease / reset font size |
| `Cmd + ,` | Settings |

tmux shortcuts are active when tmux auto-connect is enabled for the host.

---

## Recommended `tmux.conf`

```tmux
# 256-color and truecolor support
set -g default-terminal "xterm-256color"
set -ag terminal-overrides ",xterm-256color:RGB"

# Mouse support (scrolling, pane resizing, selection)
set -g mouse on

# Focus events for auto-collapsing UI and vim focus
set -g focus-events on

# Optional: let programs inside tmux (e.g. vim OSC 52 yanks) set the iOS clipboard.
# `fil copy` works without this.
set -s set-clipboard on

# Pass Filaire escape sequences (OSC 52, 777, 5100, 5101) through tmux
set -g allow-passthrough on
```

Hold `Shift` while selecting to use native iOS text selection instead of tmux's.

---

## Building

Requires macOS 14+, Xcode 16+, [XcodeGen](https://github.com/yonaskolb/XcodeGen) and [Rust](https://rustup.rs).

```bash
# Generate the Xcode project with your own bundle identifier
BUNDLE_ID=com.example.filaire xcodegen generate

# Run app tests on a simulator
xcodebuild test -scheme Filaire \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
  -skipPackagePluginValidation

# Build and test fil (add --target x86_64-unknown-linux-musl to cross-compile)
cargo build --release --manifest-path tools/fil/Cargo.toml
cargo test --manifest-path tools/fil/Cargo.toml
```

### TestFlight Deployment
Copy `.deploy.env.example` to `.deploy.env`, fill in your App Store Connect credentials (`ASC_KEY_PATH`, `ASC_KEY_ID`, `ASC_ISSUER_ID`, `DEVELOPMENT_TEAM`, `BUNDLE_ID`), then run `./deploy.sh`.

---

## License

Filaire is open source and available under the [Apache License 2.0](LICENSE.md).
