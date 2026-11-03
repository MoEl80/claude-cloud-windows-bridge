#!/usr/bin/env bash
# Helpers separated for offline regression tests (no Tailscale/model calls).
bridge_retry() {
  local attempts=$1 delay=$2
  shift 2
  local n
  for ((n=1; n<=attempts; n++)); do
    # Explicit condition prevents set -e from bypassing retry handling.
    if "$@"; then return 0; fi
    if ((n < attempts)); then sleep "$delay"; fi
  done
  return 1
}

bridge_start_daemon() {
  # Caller supplies socket/runtime/log/as_root. This function NEVER signals a PID.
  if [[ -f "$runtime/tailscaled.pid" ]]; then
    local oldpid
    read -r oldpid < "$runtime/tailscaled.pid" || true
    if [[ "${oldpid:-}" =~ ^[1-9][0-9]*$ ]] && kill -0 "$oldpid" 2>/dev/null; then
      echo 'Recorded bridge process is alive but unresponsive; left untouched. Inspect its identity before restarting.' >&2
      return 1
    fi
  fi
  rm -f -- "$socket" "$runtime/tailscaled.pid"
  nohup "${as_root[@]}" tailscaled --tun=userspace-networking --state=mem: --socket="$socket" >>"$log" 2>&1 </dev/null &
  echo "$!" > "$runtime/tailscaled.pid"
  for ((i=0; i<30; i++)); do [[ -S "$socket" ]] && return 0; sleep 1; done
  echo 'Tailscale daemon did not create its socket' >&2
  return 1
}
