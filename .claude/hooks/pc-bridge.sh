#!/usr/bin/env bash
# Cloud-only startup. Work stays on the PC, and SSH host identity is pinned.
[[ "${CLAUDE_CODE_REMOTE:-}" == true ]] || exit 0
set -euo pipefail
umask 077

# CLAUDE_PROJECT_DIR was empty in cloud sessions. The repo root is two
# levels up from this hook file and does not depend on that variable.
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="${CLAUDE_PROJECT_DIR:-$(cd -- "$script_dir/../.." && pwd)}"
source "$script_dir/bootstrap-functions.sh"

bridge_home="$HOME/.config/pc-bridge"
runtime="$HOME/.cache/pc-bridge"
mkdir -p "$bridge_home" "$runtime"
rm -f -- "$bridge_home/ready"
log="$runtime/startup.log"
: >"$log"
err() { echo "PC-Bridge: $*" >&2; }
trap 'err "startup failed. Stop work; diagnostic log: $HOME/.cache/pc-bridge/startup.log"' ERR

for variable in TS_AUTHKEY PC_HOST PC_USER PC_SSH_KEY_B64 PC_SSH_HOSTKEY_B64; do
  [[ -n "${!variable:-}" ]] || { err "missing cloud environment variable $variable"; exit 1; }
done
[[ "$PC_HOST" =~ ^[a-zA-Z0-9.-]+$ && "$PC_USER" =~ ^[a-zA-Z0-9._-]+$ ]] || { err 'Invalid PC host or user'; exit 1; }

as_root=(); [[ $(id -u) == 0 ]] || as_root=(sudo -n)

if ! command -v tailscale >/dev/null || ! command -v tailscaled >/dev/null; then
  installer=$(mktemp)
  curl -fsSL https://tailscale.com/install.sh -o "$installer"
  "${as_root[@]}" sh "$installer" >>"$log" 2>&1
  rm -f -- "$installer"
fi
command -v tailscale >/dev/null || { err 'could not install tailscale'; exit 1; }
command -v tailscaled >/dev/null || { err 'tailscaled binary missing after install'; exit 1; }

if ! command -v ssh >/dev/null || ! command -v ssh-keygen >/dev/null; then
  # Some cloud images ship without an SSH client; the bridge and helpers need ssh and ssh-keygen.
  "${as_root[@]}" apt-get install -y -qq openssh-client >>"$log" 2>&1 \
    || { "${as_root[@]}" apt-get update -qq >>"$log" 2>&1 && "${as_root[@]}" apt-get install -y -qq openssh-client >>"$log" 2>&1; }
  command -v ssh >/dev/null && command -v ssh-keygen >/dev/null \
    || { err 'could not install openssh-client (ssh, ssh-keygen)'; exit 1; }
fi

socket="$runtime/tailscaled.sock"
# NeedsLogin is a live daemon, not a stale socket. Inspect JSON even if status
# returns nonzero; do not blindly kill a PID from a file (PIDs can be reused).
ts_sock_ok() {
  [[ -S "$socket" ]] || return 1
  tailscale --socket="$socket" status --json > "$runtime/status.json" 2>>"$log" || true
  grep -q '"BackendState"[[:space:]]*:' "$runtime/status.json"
}
if ! ts_sock_ok; then bridge_start_daemon; fi

# never assume tailscale up succeeds once. A session start runs it every
# time the daemon is not logged in, with retries, and fails loudly otherwise.
ts_logged_in() { tailscale --socket="$socket" status --json 2>/dev/null | grep -q '"BackendState"[ ]*:[ ]*"Running"'; }
ts_login_once() {
  if ts_logged_in; then return 0; fi
  if ! tailscale --socket="$socket" up --auth-key="$TS_AUTHKEY" --hostname="claude-cloud-${HOSTNAME:-vm}" --accept-dns=false >>"$log" 2>&1; then
    echo 'PC-Bridge: tailscale up failed (see log)' >>"$log"
    return 1
  fi
  for ((i=0; i<10; i++)); do if ts_logged_in; then return 0; fi; sleep 1; done
  return 1
}
bridge_retry 5 2 ts_login_once || { err 'Tailscale login failed after 5 attempts (auth key or network?)'; exit 1; }

key_tmp=$(mktemp "$bridge_home/key.XXXXXX")
printf '%s' "$PC_SSH_KEY_B64" | base64 -d > "$key_tmp"
ssh-keygen -y -P '' -f "$key_tmp" >/dev/null
mv -f -- "$key_tmp" "$bridge_home/key"
printf '%s' "$PC_SSH_HOSTKEY_B64" | base64 -d > "$bridge_home/known_hosts"
# Keep the proxy command in its own script so SSH path spaces are handled correctly.
printf '#!/usr/bin/env bash\nexec %q --socket=%q nc "$@"\n' "$(command -v tailscale)" "$socket" > "$bridge_home/proxy"
chmod 700 "$bridge_home/proxy"
cat > "$bridge_home/ssh_config" <<EOF
Host pc
  HostName $PC_HOST
  User $PC_USER
  IdentityFile "$bridge_home/key"
  UserKnownHostsFile "$bridge_home/known_hosts"
  IdentitiesOnly yes
  StrictHostKeyChecking yes
  BatchMode yes
  ProxyCommand "$bridge_home/proxy" %h %p
  ConnectTimeout 15
  ServerAliveInterval 30
EOF
chmod 600 "$bridge_home/ssh_config" "$bridge_home/key" "$bridge_home/known_hosts"

# verify SSH with retries; Tailscale can take seconds to become usable.
host=''
for attempt in 1 2 3 4 5; do
  host=$(ssh -T -F "$bridge_home/ssh_config" pc hostname 2>>"$log") && break
  sleep 2
done
[[ -n "$host" ]] || { err 'could not reach PC over SSH'; exit 1; }
printf '%s\n' "$host" > "$bridge_home/ready"

# persist helpers on PATH for the session, independent of CLAUDE_PROJECT_DIR.
if [[ -n "${CLAUDE_ENV_FILE:-}" ]]; then
  printf 'export PATH=%q:$PATH\n' "$repo_root/bin" >> "$CLAUDE_ENV_FILE"
fi
printf 'PC-Bridge connected to %s. Helpers: %s/bin/{pcrun,pcget,pcput}. Work only on the PC; not this checkout.\n' "$host" "$repo_root"
