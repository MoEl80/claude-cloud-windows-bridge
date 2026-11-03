# Claude Cloud Windows Bridge

**Windows PC access for Claude Code cloud sessions.** A Claude Code cloud session (claude.ai/code) runs commands and edits the real files on **your own Windows PC** over Tailscale + SSH. Your project is not mirrored to the cloud: the agent fetches the files it needs on demand, and the master copies stay on your PC. Only this small launcher repo runs in the cloud VM.

*Unofficial community project. Not affiliated with or endorsed by Anthropic or Tailscale.*

## Why this exists

Claude's built-in option is **Remote Control**: Claude Code keeps running **on your own computer**, and claude.ai or the phone app becomes a remote screen for it ([docs](https://code.claude.com/docs/en/remote-control.md)). A cloud project can also hand a task to a folder you share that way ([docs](https://code.claude.com/docs/en/claude-projects.md#run-a-thread-on-your-own-computer)). This bridge is different: the session runs **in Anthropic's cloud** and reaches into your PC over SSH.

**In our Windows test the desktop folder-sharing path failed.** This was in November 2026, on Windows 11 with Claude Code 2.1.316 (the docs require 2.1.280 or later) and the Claude desktop app 4.4212. The folder appeared in the Remote Control list, but cloud sessions reported it as *"not available ... on Windows, [the app needs] a version that serves folders there"*. This is a version-specific result, not a claim that Remote Control doesn't support Windows; `claude remote-control` from a terminal may behave differently.

Team and Enterprise users should also look at Anthropic's official [self-hosted environments](https://code.claude.com/docs/en/self-hosted-environments). This project is for people who want a Claude-hosted cloud session working on a personal Windows PC.

There are other reasons to want it anyway:

- Remote Control needs the Claude app or `claude remote-control` running on the PC, and each connection is approved one folder at a time.
- This bridge needs only Windows' own OpenSSH service and Tailscale. A session can reach anything the configured Windows account is allowed to access, including PowerShell and installed programs.

On Linux or Mac a plain SSH setup takes about five minutes. Windows is where it gets hard:

- OpenSSH Server has to be installed and configured.
- Host-key ACLs can stop the service with error 1067 if they are wrong.
- A bash shell is needed so commands behave the same as on Linux.
- The firewall has to be locked to your tailnet.

This repo is that recipe, tested end to end.

```text
cloud VM ──Tailscale (userspace)──▶ your PC: OpenSSH (Tailscale IP only) ──▶ Git Bash as you
```

When a cloud session starts on this repo, its SessionStart hook connects the VM to your tailnet, checks your PC's pinned SSH host key, and gives the agent three helpers:

| Helper | What it does |
|---|---|
| `pcrun "cd /c/work/app && git status"` | Runs one shell command on the PC (Git Bash) |
| `pcget /c/path/file.txt ./file.txt` | Copies a PC file into the VM and prints its sha256 |
| `pcput [--expect-sha256 <hash>] ./file.txt /c/path/file.txt` | Writes a file back to the PC. It stages the full upload first, refuses symlinks and folders, then checks the expected sha256 immediately before replacement. This protects against normal stale edits but is not a filesystem lock. Windows ACLs and other metadata are not guaranteed to survive. |

Tested from two fresh cloud VMs: `whoami`, `hostname` and PowerShell work, and a 64 KB binary file survives a `pcput`/`pcget` round trip byte for byte.

## When to use it

- **Remote Control's folder connection doesn't work on your Windows PC**, or you don't want the Claude app running there. If it does work for you, it is simpler than this bridge.
- **Start work from your phone or any browser.** Your PC keeps the master files.
- **The approach is not Claude-specific.** `windows/setup-pc.ps1` works for any SSH client, and other agents can reuse `bin/` after recreating what the hook sets up (`~/.config/pc-bridge`).

It does not save money by itself. A cloud session uses the same plan usage as running Claude Code locally.

> *Dated note (November 2026):* Anthropic gave Pro and Max subscribers a one-time credit for Claude Code cloud sessions, reported to expire on 4 November 2026 (US Pacific time). Check your balance in claude.ai → Settings → Usage.

## Security: read this before setup

A connected cloud session runs commands **as the Windows account you choose**. It can do anything that account can do. In our test, an administrator account got full administrator rights over SSH, so **don't use your own admin account**.

The cloud VM holds two credentials: the **SSH private key** and a **Tailscale auth key**. Anything that runs in that session, including untrusted repository code or dependencies, could read them. Treat the cloud environment like handing the agent a key to that Windows account.

Do this:

1. **Create a dedicated standard (non-admin) Windows account**, for example `claude-bridge`, and give it access only to the folders it should work in. Use it as `-PcUser`. For this bridge, the short account name must use only letters, numbers, `.`, `_` or `-` — no spaces.
2. **Give the cloud VM its own Tailscale identity, allowed only to reach the PC on port 22.**
   - Create the auth key with a tag, for example `tag:claude-bridge`.
   - Set the key to **Reusable + Ephemeral**, with the shortest practical expiry. Reusable is required here because every fresh cloud VM starts Tailscale with in-memory state and therefore joins as a new node.
   - In your tailnet policy, allow only `tag:claude-bridge` → the PC (for example `tag:claude-bridge-target`) on `tcp:22`, and make sure no broader rule also applies.
   - Without such a policy, a new tailnet usually lets devices reach each other freely.
3. **Use a private fork of this repo and a private cloud environment.** Use a unique SSH key for this bridge only.
4. **Don't keep unrelated secrets** in folders the bridge account can read.

What the setup locks down on the PC:

- `sshd` listens only on the PC's Tailscale address.
- The firewall accepts TCP/22 on that address only from Tailscale addresses (`100.64.0.0/10`). Which tailnet devices may connect is decided by your Tailscale policy (step 2).
- Key authentication only; one allowed user; forwarding disabled.
- The cloud side pins the PC's host key.
- The cloud hook runs a **pinned Tailscale 1.104.5 static client** in userspace with in-memory state. It downloads the matching archive and SHA256 file from Tailscale's stable package server and verifies the archive before use; it does not execute Tailscale's changing `install.sh` as root.

## Setup (typically 15-30 minutes)

The PC must be on, awake and connected to Tailscale whenever you use the bridge.

### On the Windows PC

1. Install [Tailscale](https://tailscale.com/download) and sign in. Note the PC's Tailscale IP (`tailscale ip -4`, for example `100.x.y.z`). Tag the PC in the Tailscale admin console, for example `tag:claude-bridge-target`.
2. Install [Git for Windows](https://git-scm.com/download/win). Git Bash becomes the SSH shell.
3. Sign in to the **bridge account** (step 1 of the security section). Then create the bridge key **in Git Bash**:
   ```bash
   mkdir -p ~/.ssh && chmod 700 ~/.ssh
   ssh-keygen -t ed25519 -N "" -C pc-bridge -f ~/.ssh/cloud_bridge
   ```
4. Clone this repo:
   ```bash
   git clone https://github.com/MoEl80/claude-cloud-windows-bridge
   ```
   Then open **Windows PowerShell as Administrator** in that folder and run the following. Use the short account name that `whoami` shows; it is lowercased for you and must not contain spaces.
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\windows\setup-pc.ps1 -PcHost 100.x.y.z -PcUser claude-bridge
   ```
   If the key isn't in that account's `.ssh` folder, add `-PublicKeyPath`. For a non-standard Git location, add `-GitBashPath`.
   This script:
   - installs OpenSSH Server and writes a dedicated `sshd_config` (Tailscale IP, keys only, one user);
   - authorizes `cloud_bridge.pub` from the target user's profile;
   - fixes host-key ACLs;
   - auto-detects Git Bash, including a per-user Git install for the target account;
   - sets Git Bash as the default OpenSSH shell;
   - adds a Tailscale-only firewall rule;
   - disables the generic OpenSSH rule;
   - configures Windows service recovery, including recovery on non-zero error stops, so `sshd` can retry if it starts before Tailscale owns its address;
   - prints `PC_SSH_HOSTKEY_B64` from the PC's own host key, so you never pin a key from a network scan.

   It refuses to touch an existing SSH setup that it doesn't recognise. Installing OpenSSH can occasionally require a reboot: then reboot and run it again.
5. Test it locally before going to the cloud: `ssh -i ~/.ssh/cloud_bridge claude-bridge@100.x.y.z hostname` should print the PC's name.

### Collect the five values

- `PC_SSH_HOSTKEY_B64`: printed by `setup-pc.ps1`.
- `PC_SSH_KEY_B64`: in Git Bash, run `base64 -w0 ~/.ssh/cloud_bridge; echo`.
- `TS_AUTHKEY`: create a **tagged, Reusable + Ephemeral** auth key in the Tailscale admin console with a short expiry. Every fresh cloud VM is a new in-memory Tailscale node, so a one-off key will work only once.
- `PC_HOST`: the PC's Tailscale IP.
- `PC_USER`: the bridge account name.

### On claude.ai/code

1. Fork this repo (private is fine) and connect it to Claude Code on the web.
2. Create or edit a cloud environment:
   - **Network access:** full. The VM must reach Tailscale's package/control services and your tailnet.
   - **Environment variables:**
     ```text
     TS_AUTHKEY=tskey-auth-...
     PC_HOST=100.x.y.z
     PC_USER=yourwindowsuser
     PC_SSH_KEY_B64=...
     PC_SSH_HOSTKEY_B64=...
     ```
3. Start a session on your fork in that environment. The hook prints `PC-Bridge connected to <your-hostname>`.
4. Then just ask, for example: "In C:\work\app, run the tests and fix the failing one." The agent follows `AGENTS.md` and works through `pcrun`/`pcget`/`pcput`.

If the hook fails, the agent is told to stop. The log is in the VM at `~/.cache/pc-bridge/startup.log`.

## Turning it off

**Pause:** stop the `sshd` service, or disable the `PC-Bridge-SSH` firewall rule.

**Emergency cut-off**, if a key may have leaked. Do these in this order:
1. On the PC, stop `sshd`, or disable the `PC-Bridge-SSH` firewall rule.
2. Empty or replace `C:\ProgramData\ssh\pc_bridge_authorized_keys`.
3. In the Tailscale admin console, **delete the `claude-cloud-*` machines**. Revoking an auth key does not disconnect nodes that already joined.
4. Revoke the Tailscale auth key.
5. Delete the cloud environment's variables, and end any running cloud sessions.
6. Before turning the bridge on again, create a new SSH key and run `setup-pc.ps1` again.

**Uninstall:** remove the OpenSSH Server capability, the `PC-Bridge-SSH` firewall rule, `HKLM:\SOFTWARE\OpenSSH\DefaultShell` and `DefaultShellCommandOption` (note that these are machine-wide settings), `C:\ProgramData\ssh\sshd_config` and `pc_bridge_authorized_keys`, `~/.ssh/cloud_bridge*`, and the repo's `.state` folder.

## Lessons from building it

- In cloud sessions `CLAUDE_PROJECT_DIR` can be empty, so the hook derives the repo root from its own path.
- Some cloud images ship without an SSH client, so the hook installs `openssh-client` when it's missing; those package-manager calls have hard timeouts.
- The bridge uses a pinned Tailscale static build rather than running a changing remote install script as root. When intentionally upgrading it, change `TAILSCALE_VERSION` in `.claude/hooks/pc-bridge.sh` and test a fresh cloud VM.
- `tailscale up` can fail on the first try in a fresh VM, so the hook retries the login and the SSH check.
- On Windows, host keys generated by an elevated user kept that user's ACE, and the SYSTEM `sshd` service failed with error 1067. Fix: make Administrators the owner of the private host keys and remove that one ACE.
- `Get-NetTCPConnection` reported no listener while SSH worked. Judge with a real TCP connect and an actual SSH login.
- Windows reports `100.64.0.0/10` as `100.64.0.0/255.192.0.0`. Compare both forms.

## License

MIT
