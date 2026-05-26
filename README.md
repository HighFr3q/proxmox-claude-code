# Proxmox VE Helper Script — Claude Code

A single-shot installer that creates a Debian 12 LXC on a Proxmox VE host, installs the [Claude Code](https://docs.claude.com/en/docs/agents-and-tools/claude-code/overview) CLI, validates your Anthropic API key against the live API, and wires the key into the container so `claude` is ready to use the moment you `pct enter`.

In the spirit of the [community-scripts](https://community-scripts.github.io/) ecosystem. Whiptail TUI, host auto-detection (storage / bridge / architecture), one-keystroke "Default" install path for new users, and "Advanced" path for power users.

## Quick install

On your Proxmox VE host, as root:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/HighFr3q/proxmox-claude-code/main/claude-code.sh)"
```

You'll be prompted for:

- Install mode (Default / Advanced)
- Your Anthropic API key (validated live against `api.anthropic.com` before anything is baked in)

That's it. Default mode auto-picks the next free CTID, a sensible resource profile, and the first rootdir-capable storage + Linux bridge it finds on your host.

## Verify before piping to bash

Reasonable habit. Each tagged release publishes a SHA256 of the script alongside it. To verify:

```bash
curl -fsSL https://raw.githubusercontent.com/HighFr3q/proxmox-claude-code/main/claude-code.sh -o claude-code.sh
curl -fsSL https://raw.githubusercontent.com/HighFr3q/proxmox-claude-code/main/claude-code.sh.sha256
sha256sum claude-code.sh
# Compare the two hashes, then:
bash claude-code.sh
```

The script is ~370 lines of plain bash with no obfuscation — you can read every line before running it.

## Requirements

- Proxmox VE 7.x or 8.x
- Root on the PVE host
- Outbound HTTPS from the host (to download the Debian template and validate your API key) and from the container (to install Node.js + Claude Code via npm)
- A storage pool that accepts `vztmpl` content and one that accepts `rootdir` content (the defaults `local` and `local-lvm` work on a stock install)
- An Anthropic API key — get one at [console.anthropic.com](https://console.anthropic.com/)

Works on `amd64` and `arm64` Proxmox hosts (architecture is auto-detected).

## What it actually does

For the paranoid, here's the install sequence:

1. Confirms it's running on a PVE host as root.
2. Auto-detects host architecture, rootdir-capable storages, and Linux bridges.
3. Pops a whiptail menu: Default / Advanced / Exit.
4. Prompts for your API key, then calls `GET https://api.anthropic.com/v1/models` with it and only continues on HTTP 200.
5. Shows a summary screen and asks for confirmation.
6. Downloads the matching `debian-12-standard` template if it isn't already on the host.
7. Creates an unprivileged LXC with `nesting=1,keyctl=1` features.
8. Starts the container, waits for DNS to resolve.
9. Inside the container: installs `git`, `build-essential`, Node.js 20 LTS (via NodeSource), and `@anthropic-ai/claude-code` globally via npm.
10. Writes the API key to `/etc/claude-code/env` (mode 0640) and drops `/etc/profile.d/claude-code.sh` so every login shell auto-exports `ANTHROPIC_API_KEY`.
11. Prints the CTID, IP, and the two commands you need: `pct enter <CTID>` and `claude`.

If anything fails mid-create, the trap offers to roll back the half-built container automatically.

## After install

```bash
pct enter <CTID>
claude
```

The API key is sourced automatically for every login shell. To rotate it later, edit `/etc/claude-code/env` inside the container.

To update Claude Code later:

```bash
pct exec <CTID> -- npm update -g @anthropic-ai/claude-code
```

## Security notes

- The API key is **base64-encoded in transit** between the host and the container, so it never appears in any process's `argv` (and therefore not in `/proc/*/cmdline`).
- It's stored in `/etc/claude-code/env` with mode `0640` (root + adm group readable). If you create other users in the container, add them to `adm` to grant access, or tighten permissions further.
- The container runs **unprivileged**. UID 0 inside the container is not UID 0 on the host.
- No telemetry, no phone-home from this script. The only outbound calls it makes are to `download.proxmox.com` (template), `api.anthropic.com` (key validation), `deb.debian.org` + `deb.nodesource.com` + `registry.npmjs.org` (package installs).

## Troubleshooting

**"Could not find a debian-12-standard template"** — your host can't reach the Proxmox mirror, or your storage isn't named `local`. Check `pveam available --section system` and `pvesm status -content vztmpl`.

**Key validation fails with HTTP 401** — the API key was rejected. Re-check the key at [console.anthropic.com/settings/keys](https://console.anthropic.com/settings/keys).

**Container has no network** — your bridge probably doesn't have a DHCP server. Re-run in Advanced mode and pick a different bridge, or post-install do `pct set <CTID> -net0 name=eth0,bridge=<br>,ip=<cidr>,gw=<gw>`.

**`claude` says command not found inside the container** — `npm install -g` may have put it under an alternate path. Check `which claude` and `ls /usr/bin/claude`. The NodeSource Node 20 install always puts it on `$PATH`, so this would be unusual.

## Contributing

PRs welcome. Please run `shellcheck claude-code.sh` before submitting — the CI does the same.

## License

MIT — see [LICENSE](LICENSE).

This is an independent project. Not affiliated with Proxmox Server Solutions GmbH or Anthropic.
