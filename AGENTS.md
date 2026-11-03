# AGENTS.md - Claude Cloud Windows Bridge

This repository is only a launcher. The real files live on the user's PC, reached over Tailscale + SSH.

- In a cloud session, first require `$HOME/.config/pc-bridge/ready`. If it is absent, stop and report the SessionStart error; do not work in this checkout instead.
- Helpers: `<repo-root>/bin/pcrun`, `pcget`, `pcput` (also on PATH when the harness propagates it). `CLAUDE_PROJECT_DIR` may be empty; the repo root is normally `/home/user/<repo-name>`.
- `pcrun` takes exactly ONE shell-command string, run by Git Bash on the PC, e.g. `pcrun "cd '/c/work/app' && git status"`. Quote `$` deliberately.
- Edit a PC file by `pcget` to a local temp file, edit it, then `pcput` it back. Parent directories must exist. Don't overwrite changes someone else made in between.
- Run tests and commit/push the user's projects on the PC, not in this checkout.
