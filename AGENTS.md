# AGENTS.md - Claude Cloud Windows Bridge

This repository is only a launcher. The real files live on the user's PC, reached over Tailscale + SSH.

- In a cloud session, first require `$HOME/.config/pc-bridge/ready`. If it is absent, stop and report the SessionStart error; do not work in this checkout instead.
- Helpers: `<repo-root>/bin/pcrun`, `pcget`, `pcput` (also on PATH when the harness propagates it). `CLAUDE_PROJECT_DIR` may be empty; the repo root is normally `/home/user/<repo-name>`.
- `pcrun` takes exactly ONE shell-command string, run by Git Bash on the PC, e.g. `pcrun "cd '/c/work/app' && git status"`. Quote `$` deliberately.
- Edit a PC file by `pcget` to a local temp file (it prints the file's sha256), edit it, then `pcput --expect-sha256 <that hash>` it back. `pcput` stages the upload first, then rechecks the PC copy immediately before replacement and refuses a stale write if the hash no longer matches. This is optimistic concurrency protection, not a filesystem lock. Parent directories must exist.
- Run tests and commit/push the user's projects on the PC, not in this checkout.
