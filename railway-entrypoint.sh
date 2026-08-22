#!/bin/bash
# Boot order: refuse without a password, prepare the volume, start the session
# daemon, start the web/API process, then put Caddy in front of it.
set -uo pipefail

log() { printf '[railway-entrypoint] %s\n' "$*"; }

# --- 1. Refuse to boot unauthenticated -------------------------------------
# PI WEB exposes interactive terminals and read/write filesystem access. On a
# public Railway URL an unauthenticated instance is a remotely drivable shell for
# anyone who finds it, so this is a hard failure rather than a warning.
if [ -z "${PI_WEB_PASSWORD:-}" ]; then
	cat >&2 <<'MSG'
[railway-entrypoint] REFUSING TO START: PI_WEB_PASSWORD is not set.

PI WEB gives whoever reaches it interactive terminals and read/write access to the
files in this container. This service has a public URL, so it will not start without
a password.

Set PI_WEB_PASSWORD in the service variables (the template generates one for you)
and redeploy. PI_WEB_USERNAME is optional and defaults to "admin".
MSG
	exit 1
fi

if [ "${#PI_WEB_PASSWORD}" -lt 12 ]; then
	log "REFUSING TO START: PI_WEB_PASSWORD is shorter than 12 characters."
	exit 1
fi

PI_WEB_USERNAME="${PI_WEB_USERNAME:-admin}"

# --- 2. The volume ---------------------------------------------------------
# Railway mounts volumes owned by uid 0 and this image runs as root, so there is
# no chown dance here; what matters is that every writable path resolves under
# the mount, and that we notice when it is missing.
for d in /data/home /data/config /data/pi-web /data/pi-agent /data/workspace; do
	mkdir -p "$d" || { log "FATAL: cannot create $d"; exit 1; }
done

probe=/data/.write-probe
if ! ( : > "$probe" ) 2>/dev/null; then
	log "FATAL: /data is not writable (owner=$(stat -c %u:%g /data 2>/dev/null))."
	log "Attach a volume mounted at /data to this service."
	exit 1
fi
rm -f "$probe"

if ! mountpoint -q /data 2>/dev/null; then
	log "WARNING: /data is not a mount point. No volume is attached, so every workspace,"
	log "WARNING: cloned repository and session will be LOST on the next redeploy."
	log "WARNING: Attach a volume at /data."
fi

# A stale ownership marker from a container that no longer exists blocks startup.
owner=/data/pi-web/sessiond-owner.json
if [ -f "$owner" ]; then
	log "clearing sessiond ownership marker left by the previous container"
	rm -f "$owner"
fi

# git refuses to operate in directories owned by another uid; workspaces created by
# an earlier deploy are a normal case here.
git config --global --add safe.directory '*' 2>/dev/null || true
git config --global --get init.defaultBranch >/dev/null 2>&1 || git config --global init.defaultBranch main

# --- 3. Ports --------------------------------------------------------------
# Railway injects PORT into every service and PI WEB reads PORT as an override, so
# leaving it set makes PI WEB bind the public port and race Caddy for it. Hand the
# injected value to Caddy under a private name and remove PORT from PI WEB's view.
export CADDY_PORT="${PORT:-8080}"
unset PORT
export PI_WEB_PORT=8504
export PI_WEB_HOST=127.0.0.1

# --- 4. Hash the password for Caddy ---------------------------------------
PI_WEB_PASSWORD_HASH="$(caddy hash-password --plaintext "$PI_WEB_PASSWORD")" || {
	log "FATAL: could not hash PI_WEB_PASSWORD"
	exit 1
}
export PI_WEB_PASSWORD_HASH PI_WEB_USERNAME
# The plaintext stays out of the environment PI WEB hands to agent sessions, which
# inherit the daemon's environment almost as-is.
unset PI_WEB_PASSWORD

# --- 5. Session daemon -----------------------------------------------------
log "starting pi-web-sessiond"
pi-web-sessiond &
sessiond_pid=$!

for _ in $(seq 1 120); do
	[ -S "$PI_WEB_SESSIOND_SOCKET" ] && break
	kill -0 "$sessiond_pid" 2>/dev/null || { log "FATAL: sessiond exited during startup"; exit 1; }
	sleep 0.5
done
if [ ! -S "$PI_WEB_SESSIOND_SOCKET" ]; then
	log "FATAL: sessiond socket never appeared at $PI_WEB_SESSIOND_SOCKET"
	exit 1
fi
log "sessiond ready"

# --- 6. Web/API ------------------------------------------------------------
log "starting pi-web-server on 127.0.0.1:${PI_WEB_PORT}"
pi-web-server &
web_pid=$!

# --- 7. Auth proxy ---------------------------------------------------------
log "starting caddy auth proxy on :${CADDY_PORT} (user ${PI_WEB_USERNAME})"
caddy run --config /etc/caddy/Caddyfile --adapter caddyfile &
caddy_pid=$!

# Any one of the three dying means the service is broken; exit non-zero so
# Railway's ON_FAILURE restart policy replaces the container instead of leaving a
# half-running instance that answers the healthcheck but cannot start a session.
wait -n "$sessiond_pid" "$web_pid" "$caddy_pid"
status=$?
log "a supervised process exited (status ${status}); shutting down"
kill "$sessiond_pid" "$web_pid" "$caddy_pid" 2>/dev/null
exit "${status:-1}"
