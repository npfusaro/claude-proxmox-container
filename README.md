# claude-proxmox-container

A one-command Proxmox installer (in the spirit of [community-scripts.org](https://community-scripts.org))
that spins up a long-lived **Debian LXC** pre-loaded with the **Claude Code CLI** and a
baseline dev toolchain, so you can use it as a remote coding session over SSH, the Claude
**Remote Control** web/mobile UI, or **VS Code Remote-SSH**.

## What you get

- An **unprivileged** Debian LXC (Debian 13, falling back to 12) with `4 vCPU / 4 GB RAM / 32 GB disk` (all promptable).
- **Claude Code CLI** installed via the official native installer (self-contained binary, auto-updating, `ripgrep` bundled).
- Baseline tooling: `git`, `gh`, Node.js LTS, Python 3 + `pip`/`venv`/`pipx`, `build-essential`, `tmux`, `jq`, `ripgrep`, and an OpenSSH server.
- A non-root **`dev`** user (passwordless `sudo`) that owns Claude Code's credentials.
- Helper commands: `claude-start` (persistent tmux) and `claude-remote` (Remote Control).

## Design choices

| Decision | Choice | Why |
|---|---|---|
| Framework | **Standalone** (own `pct create`) | No runtime dependency on community-scripts' `build.func`/GitHub; infra you keep should be self-contained. |
| Container type | **Unprivileged**, no Docker | Most secure default; this box runs host tools only. See [Enabling Docker](#enabling-docker-later). |
| OS | **Debian** | Required for VS Code Remote-SSH (glibc); Alpine excluded. |
| Auth | **Interactive first-run login** | No secret baked into the installer — and it's the *only* auth that enables Remote Control. |
| User | **non-root `dev`** | Cleaner for VS Code Remote-SSH and credential hygiene (`~/.claude`). Root stays reachable. |
| Connectivity | **LAN / your own VPN** | Installer adds no networking. Remote Control is outbound-only, so it works without inbound ports. |

## Install

Run on the **Proxmox VE host** (as root). Once you've pushed this repo to GitHub and set the
raw URL in `ct/claude-code.sh` (replace `REPLACE-ME`):

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/npfusaro/claude-proxmox-container/main/ct/claude-code.sh)"
```

Or from a local checkout on the node:

```bash
git clone https://github.com/npfusaro/claude-proxmox-container && cd claude-proxmox-container
./ct/claude-code.sh
```

You'll be asked for container ID/host/CPU/RAM/disk/storage and **bootstrap access**: paste an
SSH public key (recommended) **or** set a password. At least one is required so you can log in.

> Preview without changing anything: `DRYRUN=1 ./ct/claude-code.sh` prints the `pct` commands instead of running them.

## First-run authentication (do this once)

```bash
ssh dev@<container-ip>
claude
```

On first launch Claude Code prints a login URL. Open it in your **laptop's** browser, sign in
with your Claude Pro/Max account, and if it shows a code, paste it back at the
`Paste code here if prompted` prompt (normal over SSH/containers). Credentials persist at
`~/.claude/.credentials.json` and survive reboots.

> Do **not** set `ANTHROPIC_API_KEY` or `CLAUDE_CODE_OAUTH_TOKEN` in this container — both take
> precedence over the subscription login and **disable Remote Control** (which requires a
> full-scope claude.ai login).

## Can't log in?

The container auto-logs in **root** on the Proxmox **Console** (web UI → CT → Console), so you
always have a way in from the Proxmox UI. From the **node shell** you can also always enter the
container with no credentials:

```bash
pct enter <CTID>
```

If SSH is refused, the key on the box doesn't match your client key. Fix it from inside the
container: overwrite `/home/dev/.ssh/authorized_keys` with your public key (then
`chown dev:dev`), or set a password and enable password auth:

```bash
passwd dev
sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
systemctl restart ssh
```

## Three ways to use it

**1. SSH + tmux** — persistent terminal session:
```bash
ssh dev@<container-ip>
claude-start          # creates/attaches a tmux session running Claude Code
```
Detach with `Ctrl-b d`; reconnect later with `claude-start` and it reattaches.

**2. Remote Control** — drive it from a browser or phone:
```bash
ssh dev@<container-ip>
claude-remote         # runs `claude remote-control` inside tmux
```
It prints a session URL / QR code; open it at [claude.ai/code](https://claude.ai/code) or in the
Claude mobile app. The session runs **locally in the container** (your files, MCP servers, tools
stay here) — the web/app is just a window into it. Requires Claude Code v2.1.51+ and a Pro/Max/
Team/Enterprise login. It's outbound-only, so no port-forwarding is needed even off-LAN.
Note: a network outage longer than ~10 minutes ends the session — just run `claude-remote` again.

**3. VS Code Remote-SSH** — GUI editor with Claude in the terminal:
1. Add to your `~/.ssh/config`:
   ```
   Host claude-box
     HostName <container-ip>
     User dev
   ```
2. In VS Code: *Remote-SSH: Connect to Host… → claude-box*.
3. Run `claude` (or `/remote-control`) in the integrated terminal.

## Persistence

Everything lives on the container's rootfs and survives reboots: your repos in
`~/projects`, and Claude Code credentials in `~/.claude`. This is a "pet" container — back it up
with a normal Proxmox backup (`vzdump`). If you'd rather make the rootfs disposable, add a
bind-mount for `~/projects` from the host (`pct set <ctid> -mp0 /host/path,mp=/home/dev/projects`);
it's intentionally not done by default.

## Enabling Docker later

The container ships unprivileged with no nesting for security. To run Docker inside it later, on
the host:
```bash
pct set <ctid> -features nesting=1,keyctl=1
pct reboot <ctid>
# then inside the container, install Docker normally
```
(`fuse=1` too if a project needs FUSE/overlay mounts.)

## Notes

- **June 15, 2026:** scripted/headless `claude -p` + Agent SDK usage on subscription plans draws
  from a separate monthly Agent SDK credit. Interactive use (the default here) is unaffected; this
  only matters if you script against the box non-interactively.
- The native installer auto-updates Claude Code in the background. Run `/usr/bin/update` for OS
  package upgrades and `claude update` to force a CLI update.

## Repo layout

```
ct/claude-code.sh               host orchestrator: prompts, pct create, push + run installer
install/claude-code-install.sh  in-container: tooling, dev user, Claude Code, helpers
misc/core.func                  shared msg_*/header/error-handling helpers
```

## Development / validation

Can't be exercised off a Proxmox host, but you can lint locally:
```bash
bash -n ct/claude-code.sh install/claude-code-install.sh misc/core.func   # parse check
shellcheck ct/claude-code.sh install/claude-code-install.sh misc/core.func # if installed
```
End-to-end test plan lives in the project plan; the short version: run the installer (or
`DRYRUN=1`), `ssh dev@<ip>`, confirm `claude`/`node`/`gh`/`tmux` work, complete `/login`, then
test `claude-remote` and VS Code Remote-SSH, and reboot to confirm persistence.
