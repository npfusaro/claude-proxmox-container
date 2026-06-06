#!/usr/bin/env bash
# ============================================================================
# claude-code.sh - Host-side orchestrator (run this on the Proxmox VE node).
#
# Creates an unprivileged Debian LXC, provisions it with the Claude Code CLI
# and a baseline dev toolchain, and sets up SSH so you can log in and run
# `claude` (interactive first-run login), `claude-start` (tmux), and
# `claude-remote` (Remote Control from claude.ai/code or the mobile app).
#
# Modeled on the community-scripts.org Proxmox VE Helper-Scripts UX, but
# self-contained (it does its own `pct create` instead of sourcing build.func).
#
# Usage (one-liner, once published to your GitHub):
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/<user>/claude-proxmox-container/main/ct/claude-code.sh)"
#
# Or from a local checkout:
#   ./ct/claude-code.sh
#
# Useful env vars:
#   REPO_RAW=...   base raw URL used to fetch sibling files when run via curl
#   DRYRUN=1       print the pct/* commands instead of executing them
#   CTID=, HOSTNAME=, DISK=, CPU=, RAM=, STORAGE=, BRIDGE=  pre-seed answers
# Copyright (c) 2026 Nick - MIT
# ============================================================================
set -Eeuo pipefail

# --- where to fetch sibling files (core.func, install script) ----------------
REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/npfusaro/claude-proxmox-container/main}"

# Resolve our own directory if running from a local checkout.
SELF_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
  SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

WORK="$(mktemp -d)"
# _stop_spinner becomes available once core.func is sourced; guard for earlier exits.
cleanup() { _stop_spinner 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT

# fetch_file <relative/path> <dest> : prefer local checkout, fall back to curl.
fetch_file() {
  local rel="$1" dest="$2"
  if [[ -n "$SELF_DIR" && -f "$SELF_DIR/$rel" ]]; then
    cp "$SELF_DIR/$rel" "$dest"
  else
    curl -fsSL "$REPO_RAW/$rel" -o "$dest"
  fi
}

# Pull in core.func for msg_* / header_info.
fetch_file "misc/core.func" "$WORK/core.func"
# shellcheck source=/dev/null
source "$WORK/core.func"

# run <cmd...> : honor DRYRUN for mutating operations.
run() {
  if [[ "${DRYRUN:-0}" == "1" ]]; then
    printf '  [dryrun] %s\n' "$*" >&2
  else
    "$@"
  fi
}

# ============================================================================
# Defaults (override via env or the prompts below)
# ============================================================================
APP="Claude-Code"
var_os="debian"
var_version="13"
var_cpu="${CPU:-4}"
var_ram="${RAM:-4096}"
var_disk="${DISK:-32}"
var_unprivileged="1"
var_bridge="${BRIDGE:-vmbr0}"
var_net="ip=dhcp"
DEV_USER="dev"
HOSTNAME_DEFAULT="${HOSTNAME:-claude-code}"

# ============================================================================
# Preflight
# ============================================================================
header_info "$APP"

[[ $EUID -eq 0 ]] || { msg_error "Run this on the Proxmox host as root."; exit 1; }
for bin in pveversion pct pvesm pveam; do
  command -v "$bin" >/dev/null 2>&1 || { msg_error "'$bin' not found - this must run on a Proxmox VE node."; exit 1; }
done
PVE_VER="$(pveversion | grep -oP 'pve-manager/\K[0-9]+' || echo 0)"
[[ "$PVE_VER" -ge 8 ]] || msg_warn "Tested on Proxmox VE 8.x/9.x; detected major version '$PVE_VER'."
[[ "$(dpkg --print-architecture)" == "amd64" ]] || msg_warn "Templates here assume amd64; detected $(dpkg --print-architecture)."

# ============================================================================
# Gather settings
# ============================================================================
CTID="${CTID:-$(pvesh get /cluster/nextid 2>/dev/null || echo 100)}"
CT_HOSTNAME="$HOSTNAME_DEFAULT"

# Pick a storage that can hold a container rootfs (content type 'rootdir').
pick_storage() {
  local content="$1" default="$2"
  local list
  list="$(pvesm status -content "$content" 2>/dev/null | awk 'NR>1 {print $1}')"
  [[ -n "$list" ]] || { msg_error "No storage with content type '$content' found."; exit 1; }
  if [[ -n "$default" ]] && grep -qx "$default" <<<"$list"; then
    echo "$default"; return
  fi
  head -n1 <<<"$list"
}
ROOTFS_STORAGE="$(pick_storage rootdir "${STORAGE:-local-lvm}")"
TMPL_STORAGE="$(pick_storage vztmpl "local")"

# Interactive overrides (skipped automatically when not on a TTY).
if [[ -t 0 && "${NONINTERACTIVE:-0}" != "1" ]]; then
  read -rp "Container ID            [$CTID]: " _x; CTID="${_x:-$CTID}"
  read -rp "Hostname                [$CT_HOSTNAME]: " _x; CT_HOSTNAME="${_x:-$CT_HOSTNAME}"
  read -rp "CPU cores               [$var_cpu]: " _x; var_cpu="${_x:-$var_cpu}"
  read -rp "RAM (MB)                [$var_ram]: " _x; var_ram="${_x:-$var_ram}"
  read -rp "Disk (GB)               [$var_disk]: " _x; var_disk="${_x:-$var_disk}"
  read -rp "rootfs storage          [$ROOTFS_STORAGE]: " _x; ROOTFS_STORAGE="${_x:-$ROOTFS_STORAGE}"
  read -rp "Network bridge          [$var_bridge]: " _x; var_bridge="${_x:-$var_bridge}"
fi

if pct status "$CTID" >/dev/null 2>&1; then
  msg_error "CTID $CTID already exists. Choose another (CTID=<n>)."
  exit 1
fi

# ============================================================================
# Bootstrap access (REQUIRED - you must be able to log in to run first-run auth)
# ============================================================================
PUBKEY_FILE=""
PW_FILE=""
collect_access() {
  echo
  echo "Bootstrap access (needed before you can run 'claude' to log in):"
  if [[ -t 0 && "${NONINTERACTIVE:-0}" != "1" ]]; then
    read -rp "  SSH public key (paste, or path to .pub, blank to skip): " key_in
    if [[ -n "$key_in" ]]; then
      if [[ -f "$key_in" ]]; then cp "$key_in" "$WORK/authorized_keys"
      else printf '%s\n' "$key_in" >"$WORK/authorized_keys"; fi
      PUBKEY_FILE="$WORK/authorized_keys"
    fi
    if [[ -z "$PUBKEY_FILE" ]]; then
      local p1 p2
      read -rsp "  Set a password for root + $DEV_USER: " p1; echo
      read -rsp "  Confirm password: " p2; echo
      [[ -n "$p1" && "$p1" == "$p2" ]] || { msg_error "Passwords empty or mismatched."; exit 1; }
      printf '%s' "$p1" >"$WORK/bootstrap_pw"; PW_FILE="$WORK/bootstrap_pw"
    fi
  else
    # Non-interactive: accept a key via env so the box is still reachable.
    if [[ -n "${SSH_PUBKEY:-}" ]]; then
      printf '%s\n' "$SSH_PUBKEY" >"$WORK/authorized_keys"; PUBKEY_FILE="$WORK/authorized_keys"
    elif [[ -n "${ROOT_PASSWORD:-}" ]]; then
      printf '%s' "$ROOT_PASSWORD" >"$WORK/bootstrap_pw"; PW_FILE="$WORK/bootstrap_pw"
    fi
  fi
  [[ -n "$PUBKEY_FILE" || -n "$PW_FILE" ]] || {
    msg_error "No access method provided. Supply an SSH key or a password (or set SSH_PUBKEY=/ROOT_PASSWORD=)."
    exit 1
  }
}
collect_access

# ============================================================================
# Ensure the OS template is present
# ============================================================================
msg_info "Updating template catalog"
run pveam update >/dev/null 2>&1 || true
msg_ok "Template catalog updated"

TEMPLATE="$(pveam available -section system 2>/dev/null | awk '{print $2}' | grep -E "^debian-${var_version}-standard" | sort -V | tail -n1 || true)"
if [[ -z "$TEMPLATE" ]]; then
  msg_warn "Debian ${var_version} template not available; falling back to Debian 12."
  var_version="12"
  TEMPLATE="$(pveam available -section system 2>/dev/null | awk '{print $2}' | grep -E "^debian-12-standard" | sort -V | tail -n1 || true)"
fi
[[ -n "$TEMPLATE" ]] || { msg_error "Could not find a Debian standard template via 'pveam available'."; exit 1; }

if ! pveam list "$TMPL_STORAGE" 2>/dev/null | grep -q "$TEMPLATE"; then
  msg_info "Downloading template $TEMPLATE"
  run pveam download "$TMPL_STORAGE" "$TEMPLATE"
  msg_ok "Template downloaded"
fi
TEMPLATE_REF="${TMPL_STORAGE}:vztmpl/${TEMPLATE}"

# ============================================================================
# Create + start the container
# ============================================================================
msg_info "Creating LXC $CTID ($CT_HOSTNAME)"
run pct create "$CTID" "$TEMPLATE_REF" \
  --hostname "$CT_HOSTNAME" \
  --cores "$var_cpu" \
  --memory "$var_ram" \
  --swap 512 \
  --rootfs "${ROOTFS_STORAGE}:${var_disk}" \
  --unprivileged "$var_unprivileged" \
  --net0 "name=eth0,bridge=${var_bridge},${var_net}" \
  --ostype "$var_os" \
  --onboot 1 \
  --description "Claude Code remote dev container - see github.com/npfusaro/claude-proxmox-container"
msg_ok "Container created"

msg_info "Starting container"
run pct start "$CTID"
msg_ok "Container started"

# Wait for the network to come up.
if [[ "${DRYRUN:-0}" != "1" ]]; then
  msg_info "Waiting for network"
  IP=""
  for _ in $(seq 1 30); do
    IP="$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}')"
    [[ -n "$IP" ]] && break
    sleep 2
  done
  [[ -n "$IP" ]] || { msg_error "Container did not get an IP address."; exit 1; }
  msg_ok "Network up: $IP"
else
  IP="<container-ip>"
fi

# ============================================================================
# Push provisioning payload and run the in-container installer
# ============================================================================
fetch_file "install/claude-code-install.sh" "$WORK/install.sh"

cat >"$WORK/bootstrap.env" <<EOF
DEV_USER="$DEV_USER"
HAS_PUBKEY="$([[ -n "$PUBKEY_FILE" ]] && echo 1 || echo 0)"
HAS_PW="$([[ -n "$PW_FILE" ]] && echo 1 || echo 0)"
EOF

msg_info "Uploading provisioning payload"
run pct exec "$CTID" -- mkdir -p /opt/claude-setup
run pct push "$CTID" "$WORK/core.func" /opt/claude-setup/core.func
run pct push "$CTID" "$WORK/install.sh" /opt/claude-setup/install.sh
run pct push "$CTID" "$WORK/bootstrap.env" /opt/claude-setup/bootstrap.env
[[ -n "$PUBKEY_FILE" ]] && run pct push "$CTID" "$PUBKEY_FILE" /opt/claude-setup/authorized_keys
[[ -n "$PW_FILE" ]] && { run pct push "$CTID" "$PW_FILE" /opt/claude-setup/bootstrap_pw; run pct exec "$CTID" -- chmod 600 /opt/claude-setup/bootstrap_pw; }
msg_ok "Payload uploaded"

msg_info "Provisioning container (this takes a few minutes)"
run pct exec "$CTID" -- bash /opt/claude-setup/install.sh
msg_ok "Provisioning complete"

# ============================================================================
# Done
# ============================================================================
echo
msg_ok "Claude Code container ${BL}$CTID${CL} is ready at ${GN}${IP}${CL}"
cat <<EOF

  Connect:        ssh ${DEV_USER}@${IP}
  First-run auth: run 'claude', then complete the login in your laptop browser
                  (it shows a code to paste back - works fine over SSH).
  Persistent CLI: claude-start    (tmux session that survives disconnects)
  Remote Control: claude-remote   (drive it from claude.ai/code or the mobile app)
                  -> requires the subscription /login above; not an API key/token.
  VS Code:        add '${DEV_USER}@${IP}' as a Remote-SSH host, run 'claude' in the terminal.

EOF
