# PI WEB on Railway

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/deploy/pi-web-or-just-updated-pi-coding-agent-i?referralCode=Z1xivh&utm_medium=integration&utm_source=template&utm_campaign=generic)

**Deploy on Railway:** [PI WEB template](https://railway.com/deploy/pi-web-or-just-updated-pi-coding-agent-i?referralCode=Z1xivh&utm_medium=integration&utm_source=template&utm_campaign=generic)

Wrapper image for [PI WEB](https://github.com/jmfederico/pi-web) — a web UI that keeps
[Pi Coding Agent](https://www.npmjs.com/package/@earendil-works/pi-coding-agent) sessions alive in
real workspaces: projects, files, terminals, sessions.

- **Image:** `ghcr.io/bon5co/pi-web-railway:latest`
- **Volume mount path:** `/data` (workspaces, repos, session history, Pi login)
- **Healthcheck:** `/healthz`

## Why this image exists

Upstream ships **no authentication**, and says so in its own README:

> It is not a sandbox, permission system, or multi-tenant platform. Do not expose it directly to
> the public internet without a trusted network, firewall, VPN, SSH tunnel, or authenticated
> reverse proxy.

A Railway service has a public URL, and PI WEB's surface includes interactive terminals and
read/write filesystem access. So this image ships the authenticated reverse proxy upstream asks
for: Caddy terminates the public port and enforces HTTP basic auth on the UI, the API and the
WebSocket bridge, and the entrypoint refuses to start when `PI_WEB_PASSWORD` is unset or shorter
than 12 characters.

## Variables

| Variable | Required | Purpose |
|---|---|---|
| `PI_WEB_PASSWORD` | **yes** | Basic-auth password. The container refuses to boot without it. |
| `PI_WEB_USERNAME` | no | Basic-auth user, defaults to `admin`. |

The LLM credential is not an environment variable: Pi Coding Agent stores its own credentials under
`PI_CODING_AGENT_DIR` (`/data/pi-agent`, on the volume), and you sign in to your provider from
PI WEB's own auth dialog after logging in. That login survives redeploys.

## What is pinned

PI WEB `1.202608.1`, Pi Coding Agent `0.84.2` (resolved as PI WEB's npm peer), Caddy `2.10.2`,
Node 22, Debian bookworm. Bump the `PI_WEB_VERSION` build arg to move deliberately.
