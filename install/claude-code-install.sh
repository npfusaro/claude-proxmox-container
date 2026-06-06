#!/usr/bin/env bash
# ============================================================================
# claude-code-install.sh - runs INSIDE the freshly created Debian LXC.
# Invoked by ct/claude-code.sh via `pct exec`. Installs the dev toolchain,
# the Claude Code CLI, a non-root `dev` user, SSH access and helper scripts.
# Copyright (c) 2026 Nick - MIT
# ============================================================================
set -Eeuo pipefail

# shellcheck source=/dev/null
source /opt/claude-setup/core.func
catch_errors

# Defaults; overridden by the env file pushed from the host.
DEV_USER="dev"
HAS_PUBKEY=0
HAS_PW=0
# shellcheck source=/dev/null
[[ -f /opt/claude-setup/bootstrap.env ]] && source /opt/claude-setup/bootstrap.env

export DEBIAN_FRONTEND=noninteractive
# Keep unattended apt fully non-interactive (needrestart ships on Debian 12/13).
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1
# Run the install under the always-present C.UTF-8 so apt/perl/locale don't warn
# before en_US.UTF-8 is generated (LANG may be inherited from the host via pct exec).
# The persistent default is switched to en_US.UTF-8 later via update-locale.
export LANG=C.UTF-8 LC_ALL=C.UTF-8
# Our output is streamed through `pct exec` (which passes a TTY), so disable the
# spinner here: plain status lines stream cleanly instead of colliding with apt.
export NO_SPINNER=1

# ----------------------------------------------------------------------------
# Base system: locale, timezone, update
# ----------------------------------------------------------------------------
msg_info "Configuring locale and updating base system"
apt-get update -qq
apt-get install -y -qq locales >/dev/null
sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen >/dev/null 2>&1
update-locale LANG=en_US.UTF-8 >/dev/null 2>&1
apt-get upgrade -y -qq >/dev/null
msg_ok "Base system ready"

# ----------------------------------------------------------------------------
# Baseline dev tooling (host tools only - no Docker by default)
# ----------------------------------------------------------------------------
msg_info "Installing baseline packages"
apt-get install -y -qq \
  curl wget git ca-certificates gnupg apt-transport-https \
  build-essential ripgrep jq unzip tar less vim nano htop \
  tmux openssh-server sudo \
  python3 python3-pip python3-venv pipx >/dev/null
msg_ok "Baseline packages installed"

# Node.js LTS (needed for npx-based MCP servers and most JS projects;
# the Claude Code binary itself does not require Node).
msg_info "Installing Node.js LTS"
# Non-fatal: Claude Code itself doesn't need Node, so a NodeSource hiccup must
# not abort the whole provision. (Failure in an `if` test does not trip set -e.)
if curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - >/dev/null 2>&1 \
  && apt-get install -y -qq nodejs >/dev/null 2>&1; then
  msg_ok "Node.js $(node -v 2>/dev/null) installed"
else
  msg_warn "Node.js install failed; continuing. Install later with: curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - && sudo apt-get install -y nodejs"
fi

# GitHub CLI
msg_info "Installing GitHub CLI"
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg 2>/dev/null
chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
  >/etc/apt/sources.list.d/github-cli.list
apt-get update -qq
apt-get install -y -qq gh >/dev/null
msg_ok "GitHub CLI installed"

# ----------------------------------------------------------------------------
# Non-root dev user + access
# ----------------------------------------------------------------------------
msg_info "Creating user '$DEV_USER'"
id "$DEV_USER" &>/dev/null || useradd -m -s /bin/bash "$DEV_USER"
usermod -aG sudo "$DEV_USER"
# Passwordless sudo: this is a personal LAN/VPN-only dev box; convenient and
# documented in the README. Remove this file to require a sudo password.
echo "$DEV_USER ALL=(ALL) NOPASSWD:ALL" >/etc/sudoers.d/90-"$DEV_USER"
chmod 440 /etc/sudoers.d/90-"$DEV_USER"
DEV_HOME="/home/$DEV_USER"
install -d -m 700 -o "$DEV_USER" -g "$DEV_USER" "$DEV_HOME/.ssh"
install -d -m 755 -o "$DEV_USER" -g "$DEV_USER" "$DEV_HOME/projects"

if [[ "$HAS_PUBKEY" == "1" && -f /opt/claude-setup/authorized_keys ]]; then
  cp /opt/claude-setup/authorized_keys "$DEV_HOME/.ssh/authorized_keys"
  chown "$DEV_USER:$DEV_USER" "$DEV_HOME/.ssh/authorized_keys"
  chmod 600 "$DEV_HOME/.ssh/authorized_keys"
fi
if [[ "$HAS_PW" == "1" && -f /opt/claude-setup/bootstrap_pw ]]; then
  pw="$(cat /opt/claude-setup/bootstrap_pw)"
  echo "root:$pw" | chpasswd
  echo "$DEV_USER:$pw" | chpasswd
fi
msg_ok "User '$DEV_USER' configured"

# ----------------------------------------------------------------------------
# SSH server (key-only if no password was set)
# ----------------------------------------------------------------------------
msg_info "Enabling SSH"
if [[ "$HAS_PW" != "1" ]]; then
  sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
fi
systemctl enable --now ssh >/dev/null 2>&1 || systemctl enable --now sshd >/dev/null 2>&1 || true
msg_ok "SSH enabled"

# ----------------------------------------------------------------------------
# Root auto-login on the container console (Proxmox UI "Console" / `pct console`).
# Without this a key-only container has NO way to log in at the console prompt.
# The console already requires Proxmox host access (root-equivalent), so this
# matches community-scripts behavior and is the standard convenience tradeoff.
# ----------------------------------------------------------------------------
msg_info "Enabling root console auto-login"
mkdir -p /etc/systemd/system/console-getty.service.d
cat >/etc/systemd/system/console-getty.service.d/autologin.conf <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear --keep-baud console 115200,38400,9600 $TERM
EOF
systemctl daemon-reload >/dev/null 2>&1 || true
systemctl restart console-getty >/dev/null 2>&1 || true
msg_ok "Console auto-login enabled"

# ----------------------------------------------------------------------------
# Claude Code (native installer - self-contained binary, auto-updating)
# Installed as the dev user so credentials live under /home/$DEV_USER/.claude.
# ----------------------------------------------------------------------------
msg_info "Installing Claude Code CLI"
sudo -u "$DEV_USER" -H bash -lc 'curl -fsSL https://claude.ai/install.sh | bash' >/dev/null 2>&1
# shellcheck disable=SC2016  # intentionally literal: $HOME/$PATH expand in dev's shell, not now
grep -q '.local/bin' "$DEV_HOME/.bashrc" 2>/dev/null \
  || echo 'export PATH="$HOME/.local/bin:$PATH"' >>"$DEV_HOME/.bashrc"
chown "$DEV_USER:$DEV_USER" "$DEV_HOME/.bashrc"
CC_BIN="$DEV_HOME/.local/bin/claude"
[[ -x "$CC_BIN" ]] || { msg_error "Claude Code binary not found at $CC_BIN after install."; exit 1; }
CC_VER="$(sudo -u "$DEV_USER" -H "$CC_BIN" --version 2>/dev/null || echo 'installed')"
msg_ok "Claude Code ready ($CC_VER)"

# ----------------------------------------------------------------------------
# Helper scripts + tmux config + MOTD
# ----------------------------------------------------------------------------
msg_info "Installing helper scripts"

cat >/usr/local/bin/claude-start <<'EOF'
#!/usr/bin/env bash
# Start/attach a persistent tmux session running Claude Code.
set -euo pipefail
SESSION="claude"
cd "${1:-$HOME/projects}" 2>/dev/null || cd "$HOME"
if tmux has-session -t "$SESSION" 2>/dev/null; then
  exec tmux attach -t "$SESSION"
fi
exec tmux new-session -s "$SESSION" "claude; exec bash"
EOF

cat >/usr/local/bin/claude-remote <<'EOF'
#!/usr/bin/env bash
# Start Claude Code Remote Control in a persistent tmux session, so you can
# drive this box from claude.ai/code or the Claude mobile app.
# Requires a claude.ai subscription login first: run `claude`, then /login.
# (Remote Control does NOT work with an API key or a setup-token.)
set -euo pipefail
SESSION="claude-remote"
cd "${1:-$HOME/projects}" 2>/dev/null || cd "$HOME"
if tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "Remote Control already running. Attaching (Ctrl-b d to detach)..."
  exec tmux attach -t "$SESSION"
fi
exec tmux new-session -s "$SESSION" "claude remote-control --name \"$(hostname)\"; exec bash"
EOF

chmod 755 /usr/local/bin/claude-start /usr/local/bin/claude-remote

cat >"$DEV_HOME/.tmux.conf" <<'EOF'
set -g default-terminal "screen-256color"
set -g mouse on
set -g history-limit 50000
setw -g mode-keys vi
EOF
chown "$DEV_USER:$DEV_USER" "$DEV_HOME/.tmux.conf"

cat >/etc/profile.d/zz-claude-code.sh <<'EOF'
if [ -n "${PS1:-}" ]; then
  cat <<'BANNER'

  === Claude Code dev container ===
  claude          first-run login (open the URL on your laptop, paste the code back)
  claude-start    persistent tmux session for SSH use
  claude-remote   Remote Control -> steer from claude.ai/code or the mobile app
  ~/projects      put your repos here (persists across reboots)

BANNER
fi
EOF

cat >/usr/bin/update <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update && apt-get -y upgrade
echo "Claude Code auto-updates in the background; run 'claude update' to force."
EOF
chmod 755 /usr/bin/update
msg_ok "Helper scripts installed"

# ----------------------------------------------------------------------------
# Cleanup (remove the bootstrap payload incl. any password file)
# ----------------------------------------------------------------------------
msg_info "Cleaning up"
apt-get -y -qq autoremove >/dev/null 2>&1 || true
apt-get -y -qq clean >/dev/null 2>&1 || true
rm -rf /opt/claude-setup
msg_ok "Done"
