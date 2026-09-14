# `fil` — Filaire iOS Companion CLI

A lightweight, zero-dependency remote companion CLI for **Filaire** terminal sessions.

`fil` bridges your remote dev machine with your iPad/iPhone over standard SSH terminal streams (using in-band OSC escape sequences), requiring no open ports, background daemons, or firewall configurations.

---

## Features

- **Clipboard Sync (`fil` / `fil copy`):** Pipe stdout or pass files/text to copy directly to your iOS system clipboard (via OSC 52). Works inside and outside `tmux`.
- **Native Notifications (`fil notify`):** Trigger native iOS notification banners and tactile haptics upon long-running task completion (via OSC 777).
- **Open Links (`fil open`):** Open URLs directly in iOS Safari (via OSC 8).

---

## Usage

### 1. Clipboard Copy
```bash
# Pipe any command output directly to your iOS clipboard
cat file.foo | fil
git diff | fil
cargo build 2>&1 | fil

# Copy a file by path
fil copy ~/.ssh/id_ed25519.pub

# Copy text arguments directly
fil "SecretToken12345"
```

### 2. Native Notifications
```bash
# Notify when a build or long-running command finishes
cargo build --release && fil notify "Build succeeded!" -t "Cargo"

# Simple notification
fil notify "Database backup completed"
```

### 3. Open Links in Safari
```bash
fil open "https://example.com"
```

### 4. SSH Agent Forwarding
Forwarded authentication connects to your iOS biometric SSH keys via `fil agent`:
- Enable **SSH Agent Forwarding** per host in Filaire (Settings → Hosts → [Host] → Security), and optionally select specific keys to forward.
- Connect your shell session to the forwarded agent:
  ```bash
  eval $(fil agent)
  ssh-add -l
  ```
- The bridge configuration lives in `~/.filaire/agent` (mode `0600`) and is readable only by you.
- Each forwarded signing request triggers Face ID / Touch ID on your iOS device.

---

## Installation on Remote Server

```bash
# From within the repository on the remote machine
cargo install --path tools/fil

# Or compile a release binary and copy to your PATH
cargo build --release --manifest-path tools/fil/Cargo.toml
cp tools/fil/target/release/fil ~/.local/bin/
```
