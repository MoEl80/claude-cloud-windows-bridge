# Changelog

## November 2026 hardening update

Changes since the first public version, after independent reviews:

**Windows setup (`windows/setup-pc.ps1`)**
- The Windows username is lowercased and must match `a-z 0-9 . _ -`. This matches OpenSSH `AllowUsers` and the cloud-side check, and the account must exist.
- The public key is read from the target account's profile (or `-PublicKeyPath`), not from the elevated installer's profile.
- Git Bash is auto-detected, including a per-user Git install for the target account (or `-GitBashPath`).
- `sshd` service recovery: `sc.exe failure` plus `sc.exe failureflag sshd 1`, checked with `qfailure`/`qfailureflag`.
- The PC prints `PC_SSH_HOSTKEY_B64` from its own host key, so pinning no longer depends on a network scan.
- Removed two `sshd_config` directives that Windows OpenSSH does not support.

**Cloud side (`.claude/hooks`, `bin/`)**
- Tailscale is a pinned 1.104.5 static client, downloaded from Tailscale's stable package server and checked against the published SHA256. The hook no longer runs Tailscale's changing `install.sh` as root.
- Hard timeouts on network steps, including the `apt-get` fallback.
- Temporary private-key file is removed by a cleanup trap if setup fails.
- `pcget` prints the file's sha256. `pcput --expect-sha256` stages the upload first, then checks the hash immediately before replacement. This is optimistic concurrency protection, not a filesystem lock.
- `pcget`/`pcput` refuse folder destinations.

**Documentation**
- Security section first: a dedicated standard (non-admin) Windows account, and a tagged Tailscale identity limited to the PC on `tcp:22`.
- The auth key must be **tagged + Reusable + Ephemeral + short expiry**, because every fresh cloud VM is a new in-memory Tailscale node.
- A corrected emergency cut-off order: deleting already-joined nodes is separate from revoking the key.
- A clear distinction from Claude Remote Control, and a note on Anthropic's self-hosted environments.

**Validation**
- Bash syntax checks and Windows PowerShell parser checks passed.
- The Tailscale 1.104.5 archive download/checksum/layout test passed.
- Earlier real cloud testing verified command execution, PowerShell and a binary file round trip.
- Not yet verified: broad re-testing of the pinned client across fresh cloud VMs, and a real reboot test with Tailscale starting late.
