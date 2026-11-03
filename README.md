# Claude Cloud Windows Bridge

**Windows PC access for cloud coding agents.** A Claude Code cloud session (claude.ai/code), or any Linux cloud VM, runs commands and edits the real files on **your own Windows PC** over Tailscale + SSH. Nothing is synced or cloned. The cloud VM is only a thin launcher.

On Linux or Mac this is a five-minute job. Windows is where it gets hard: OpenSSH Server, host-key ACLs that crash the service, a bash shell so commands behave the same as on Linux, and a firewall locked to your tailnet. This repo is that recipe, tested end to end.

```
cloud VM ──Tailscale (userspace)──▶ your PC: OpenSSH (Tailscale IP only) ──▶ Git Bash as you
```

When a cloud session starts on this repo, its SessionStart hook connects the VM to your tailnet, checks your PC's pinned SSH host key, and gives the agent three helpers:

| Helper | What it does |
|---|---|
| `pcrun "cd /c/work/app && git status"` | Runs one shell command on the PC (Git Bash) |
| `pcget /c/path/file.txt ./file.txt` | Copies a PC file into the VM |
| `pcput ./file.txt /c/path/file.txt` | Writes a file back to the PC. It stages the file next to the destination and refuses symlinks |

Tested from two fresh cloud VMs: `whoami`, `hostname` and PowerShell work, and a 64 KB binary file survives a `pcput`/`pcget` round trip byte for byte.

## When to use it

- **The PC needs no Claude app running.** It only needs the `sshd` service and Tailscale. Anthropic's built-in Remote Control / folder connection needs the Claude app or `claude remote-control` running on the machine. If that works for you, it is simpler.
- **Start work from your phone or any browser.** Your PC keeps the master files.
- **Not tied to Claude.** The hook is Claude Code specific, but `bin/` and `windows/setup-pc.ps1` work for any CI job, agent or script that can run bash on Linux.

It does not save money by itself. A cloud session uses the same plan usage as running Claude Code locally.

> **Note on the 2026 cloud-session credit:** Anthropic gave Pro and Max subscribers a one-time credit for Claude Code cloud sessions, which expires on 4 November 2026 (US Pacific time). If you still have some, spend it before then. This bridge points that work at your real PC. Check the balance in claude.ai → Settings → Usage.

## What access this grants

A session that connects runs commands **as your Windows user, on the whole PC**: every folder and every installed program. If that user is an administrator, the session is elevated too. Only use it with sessions you control.

The network exposure is kept small:

- `sshd` listens only on your Tailscale IP.
- The firewall rule allows only `100.64.0.0/10` (your tailnet).
- Key authentication only; no passwords.
- `AllowUsers` lists one user.
- Forwarding is disabled.
- The cloud side pins your host key and runs Tailscale in userspace with in-memory state, as an ephemeral node.

## Setup (about 15 minutes)

### On the Windows PC

1. Install [Tailscale](https://tailscale.com/download) and sign in. Note the PC's Tailscale IP (`tailscale ip -4`, for example `100.x.y.z`).
2. Install [Git for Windows](https://git-scm.com/download/win). Git Bash becomes the SSH shell.
3. Create the bridge key **in Git Bash**:
   ```bash
   ssh-keygen -t ed25519 -N "" -C pc-bridge -f ~/.ssh/cloud_bridge
   ```
4. Clone this repo, open **PowerShell as Administrator** in it, and run:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\windows\setup-pc.ps1 -PcHost 100.x.y.z -PcUser yourwindowsuser
   ```
   This script:
   - installs OpenSSH Server and writes a dedicated `sshd_config` (Tailscale IP, keys only, one user);
   - authorizes `cloud_bridge.pub`;
   - fixes host-key ACLs;
   - sets Git Bash as the default shell;
   - adds a Tailscale-only firewall rule;
   - disables the generic OpenSSH rule.

   It refuses to touch an existing SSH setup that it doesn't recognise.

### Collect the five values (in Git Bash on the PC)

```bash
base64 -w0 ~/.ssh/cloud_bridge; echo                  # -> PC_SSH_KEY_B64
ssh-keyscan -t ed25519 100.x.y.z | base64 -w0; echo   # -> PC_SSH_HOSTKEY_B64
```

Create an auth key in the Tailscale admin console with **Reusable** and **Ephemeral** turned on. That gives `TS_AUTHKEY`.

### On claude.ai/code

1. Fork this repo (private is fine) and connect it to Claude Code on the web.
2. Create or edit a cloud environment:
   - **Network access:** full. The VM must reach Tailscale.
   - **Environment variables:**
     ```
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

- **Pause:** stop the `sshd` service, or disable the `PC-Bridge-SSH` firewall rule.
- **Cut off cloud access:** revoke the Tailscale auth key and delete the environment variables.
- **Uninstall:** remove the OpenSSH Server capability, the `PC-Bridge-SSH` firewall rule, `HKLM:\SOFTWARE\OpenSSH\DefaultShell`, and `~/.ssh/cloud_bridge*`.

## Lessons from building it

- In cloud sessions `CLAUDE_PROJECT_DIR` can be empty, so the hook derives the repo root from its own path.
- Some cloud images ship without an SSH client, so the hook installs `openssh-client` when it's missing.
- `tailscale up` can fail on the first try in a fresh VM, so the hook retries the login and the SSH check.
- On Windows, host keys generated by an elevated user kept that user's ACE, and the SYSTEM `sshd` service failed with error 1067. Fix: make Administrators the owner of the private host keys and remove that one ACE.
- `Get-NetTCPConnection` reported no listener while SSH worked. Judge with a real TCP connect and an actual SSH login.
- Windows reports `100.64.0.0/10` as `100.64.0.0/255.192.0.0`. Compare both forms.

## License

MIT
