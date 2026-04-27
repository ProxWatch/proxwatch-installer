# proxwatch-installer

The official ProxWatch install script. This is the public, auditable source of the one-line installer served from `https://proxwatch.com/install.sh`.

[**ProxWatch website**](https://proxwatch.com) · [Manual](https://proxwatch.com/manual) · [Live demo](https://demo.proxwatch.com)

---

## Install ProxWatch

On a fresh **Debian 12** or **Ubuntu 22.04+** host, as root:

```bash
apt update && apt install -y curl && curl -fsSL https://proxwatch.com/install.sh | bash
```

The installer finishes in 1–3 minutes. When it's done, open the URL it prints (typically `http://<your-server-ip>:3000`) and finish the setup wizard.

## What this script does

- Detects OS, architecture, and root permissions
- Installs Docker Engine + Docker Compose v2 if missing
- Runs an LXC + overlayfs smoke test before continuing — with a triaged error pointing at the docs if container nesting isn't enabled
- Generates secure secrets and writes `/opt/proxwatch/.env`
- Writes `/opt/proxwatch/docker-compose.yml`
- Pulls the ProxWatch images from GitHub Container Registry (`ghcr.io/proxwatch`)
- Starts the stack and prints the URL to open in a browser
- Idempotent — safe to re-run after a partial failure

## System requirements

| | Homelab | Production |
|---|---|---|
| OS | Debian 12 or Ubuntu 22.04+ | same |
| Architecture | x86_64 | x86_64 |
| CPU | 2 cores | 4+ cores |
| RAM | 4 GB | 8–12 GB |
| Disk | 20 GB | 40+ GB |
| Network | Outbound HTTPS to `ghcr.io` and `proxwatch.com` | same |

## Inspect before you run

This repository **is the source**. If you want to read the script before piping it to `bash`:

```bash
curl -fsSL https://proxwatch.com/install.sh | less
```

Or just browse [`install.sh`](./install.sh) above.

## wget alternative

For hosts that ship with `wget` but no `curl`:

```bash
apt update && apt install -y wget && wget -qO- https://proxwatch.com/install.sh | bash
```

## LXC users

If you're installing inside a Proxmox LXC container, enable container features on the host first:

```bash
pct set <CTID> -features nesting=1,keyctl=1
pct stop <CTID> && pct start <CTID>
```

Then run the installer inside the container.

For the easiest support path, a **full VM** is the recommended deployment. See [LXC vs VM Guidance](https://proxwatch.com/manual/getting-started/lxc-vs-vm).

## Updating

The installer ships a bundled update script:

```bash
proxwatch-update
```

It pulls the latest images, runs any pending database migrations, and restarts the services. Existing data and configuration are preserved.

## Where things live after install

| Path | Contents |
|---|---|
| `/opt/proxwatch/docker-compose.yml` | Compose stack |
| `/opt/proxwatch/.env` | Generated secrets — **back this up** |
| `/opt/proxwatch/data/` | Postgres volume + worker state |

## Documentation

- [Install guide](https://proxwatch.com/install)
- [Quick Start](https://proxwatch.com/manual/getting-started/quick-start)
- [Troubleshooting](https://proxwatch.com/manual/troubleshooting)
- [Full Manual](https://proxwatch.com/manual)

## Reporting issues

Open an issue here for **installer-specific** bugs (script fails, OS detection wrong, Docker install hiccups, etc.).

For **product** issues (dashboard bugs, license activation, SSH polling, etc.) email **support@proxwatch.com** — that goes into our triage system with full ticket tracking.

## Security

Found a security issue? Please **don't open a public issue**. See [SECURITY.md](./SECURITY.md) for responsible disclosure.

## License

MIT. See [LICENSE](./LICENSE).

---

Built by **ProxWatch LLC**. Try the [live demo](https://demo.proxwatch.com) — no signup needed.
