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
key_tmp=''
tmp_cleanup=()
cleanup_exit() {
  [[ -z "${key_tmp:-}" ]] || rm -f -- "$key_tmp"
  local p
  for p in "${tmp_cleanup[@]:-}"; do [[ -z "$p" ]] || rm -rf -- "$p"; done
}
trap cleanup_exit EXIT
trap 'err "startup failed. Stop work; diagnostic log: $HOME/.cache/pc-bridge/startup.log"' ERR

for variable in TS_AUTHKEY PC_HOST PC_USER PC_SSH_KEY_B64 PC_SSH_HOSTKEY_B64; do
  [[ -n "${!variable:-}" ]] || { err "missing cloud environment variable $variable"; exit 1; }
done
[[ "$PC_HOST" =~ ^[a-zA-Z0-9.-]+$ && "$PC_USER" =~ ^[a-zA-Z0-9._-]+$ ]] || { err 'Invalid PC host or user'; exit 1; }

for command_name in curl timeout tar sha256sum; do
  command -v "$command_name" >/dev/null || { err "required command missing in cloud image: $command_name"; exit 1; }
done

# Pin the Tailscale client used by the bridge. Static binaries avoid executing a
# changing curl|sh installer as root in a VM that also holds the bridge credentials.
TAILSCALE_VERSION='1.104.5'
case "$(uname -m)" in
  x86_64|amd64) ts_arch='amd64' ;;
  aarch64|arm64) ts_arch='arm64' ;;
  *) err "unsupported cloud CPU architecture for pinned Tailscale: $(uname -m)"; exit 1 ;;
esac
tailscale_home="$bridge_home/tailscale-$TAILSCALE_VERSION-$ts_arch"
tailscale_bin="$tailscale_home/tailscale"
tailscaled_bin="$tailscale_home/tailscaled"
ts_have=''
if [[ -x "$tailscale_bin" && -x "$tailscaled_bin" ]]; then
  ts_have=$("$tailscale_bin" version 2>/dev/null | head -n1 || true)
fi
if [[ "$ts_have" != "$TAILSCALE_VERSION" ]]; then
  rm -rf -- "$tailscale_home"
  ts_tmp=$(mktemp -d "$runtime/tailscale-install.XXXXXX")
  tmp_cleanup+=("$ts_tmp")
  ts_archive="tailscale_${TAILSCALE_VERSION}_${ts_arch}.tgz"
  ts_url="https://pkgs.tailscale.com/stable/$ts_archive"
  curl -fsSL --connect-timeout 15 --max-time 180 --retry 3 "$ts_url" -o "$ts_tmp/$ts_archive"
  curl -fsSL --connect-timeout 15 --max-time 60 --retry 3 "$ts_url.sha256" -o "$ts_tmp/$ts_archive.sha256"
  (cd "$ts_tmp" && sha256sum -c "$ts_archive.sha256") >>"$log" 2>&1
  tar -xzf "$ts_tmp/$ts_archive" -C "$ts_tmp"
  extracted="$ts_tmp/tailscale_${TAILSCALE_VERSION}_${ts_arch}"
  [[ -x "$extracted/tailscale" && -x "$extracted/tailscaled" ]] || { err 'pinned Tailscale archive did not contain the expected binaries'; exit 1; }
  mkdir -p "$tailscale_home"
  cp -- "$extracted/tailscale" "$tailscale_bin"
  cp -- "$extracted/tailscaled" "$tailscaled_bin"
  chmod 700 "$tailscale_bin" "$tailscaled_bin"
fi
[[ "$("$tailscale_bin" version 2>/dev/null | head -n1)" == "$TAILSCALE_VERSION" ]] || { err 'pinned Tailscale version verification failed'; exit 1; }

as_root=(); [[ $(id -u) == 0 ]] || as_root=(sudo -n)
if ! command -v ssh >/dev/null || ! command -v ssh-keygen >/dev/null; then
  command -v apt-get >/dev/null || { err 'ssh/ssh-keygen missing and this cloud image has no apt-get'; exit 1; }
  # Some cloud images ship without an SSH client. Bound package-manager network waits too.
  timeout 180 "${as_root[@]}" apt-get install -y -qq openssh-client >>"$log" 2>&1 \
    || { timeout 180 "${as_root[@]}" apt-get update -qq >>"$log" 2>&1 && timeout 180 "${as_root[@]}" apt-get install -y -qq openssh-client >>"$log" 2>&1; }
  command -v ssh >/dev/null && command -v ssh-keygen >/dev/null \
    || { err 'could not install openssh-client (ssh, ssh-keygen)'; exit 1; }
fi

socket="$runtime/tailscaled.sock"
# NeedsLogin is a live daemon, not a stale socket. Inspect JSON even if status
# returns nonzero; do not blindly kill a PID from a file (PIDs can be reused).
ts_sock_ok() {
  [[ -S "$socket" ]] || return 1
  timeout 10 "$tailscale_bin" --socket="$socket" status --json > "$runtime/status.json" 2>>"$log" || true
  grep -q '"BackendState"[[:space:]]*:' "$runtime/status.json"
}
if ! ts_sock_ok; then bridge_start_daemon; fi

# Never assume tailscale up succeeds once. Each cloud VM has in-memory Tailscale
# state, so the environment's auth key must be tagged + reusable + ephemeral.
ts_logged_in() { timeout 10 "$tailscale_bin" --socket="$socket" status --json 2>/dev/null | grep -q '"BackendState"[ ]*:[ ]*"Running"'; }
ts_login_once() {
  if ts_logged_in; then return 0; fi
  if ! timeout 60 "$tailscale_bin" --socket="$socket" up --auth-key="$TS_AUTHKEY" --hostname="claude-cloud-${HOSTNAME:-vm}" --accept-dns=false >>"$log" 2>&1; then
    echo 'PC-Bridge: tailscale up failed (see log)' >>"$log"
    return 1
  fi
  for ((i=0; i<10; i++)); do if ts_logged_in; then return 0; fi; sleep 1; done
  return 1
}
bridge_retry 5 2 ts_login_once || { err 'Tailscale login failed after 5 attempts (auth key reusable/ephemeral/tag settings or network?)'; exit 1; }

key_tmp=$(mktemp "$bridge_home/key.XXXXXX")
printf '%s' "$PC_SSH_KEY_B64" | base64 -d > "$key_tmp"
ssh-keygen -y -P '' -f "$key_tmp" >/dev/null
mv -f -- "$key_tmp" "$bridge_home/key"
key_tmp=''
printf '%s' "$PC_SSH_HOSTKEY_B64" | base64 -d > "$bridge_home/known_hosts"
# Keep the proxy command in its own script so SSH path spaces are handled correctly.
printf '#!/usr/bin/env bash\nexec %q --socket=%q nc "$@"\n' "$tailscale_bin" "$socket" > "$bridge_home/proxy"
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

# Verify SSH with retries; Tailscale can take seconds to become usable.
host=''
for attempt in 1 2 3 4 5; do
  host=$(timeout 30 ssh -T -F "$bridge_home/ssh_config" pc hostname 2>>"$log") && break
  sleep 2
done
[[ -n "$host" ]] || { err 'could not reach PC over SSH'; exit 1; }
printf '%s\n' "$host" > "$bridge_home/ready"

# Persist helpers on PATH for the session, independent of CLAUDE_PROJECT_DIR.
if [[ -n "${CLAUDE_ENV_FILE:-}" ]]; then
  printf 'export PATH=%q:$PATH\n' "$repo_root/bin" >> "$CLAUDE_ENV_FILE"
fi
printf 'PC-Bridge connected to %s. Helpers: %s/bin/{pcrun,pcget,pcput}. Work only on the PC; not this checkout.\n' "$host" "$repo_root"
