# splitroute (macOS)

`splitroute` is a lightweight split-routing tool for macOS.
You keep normal internet traffic on one interface (for example Ethernet), and route selected services (for example OpenAI/ChatGPT/Codex) through another interface (for example iPhone hotspot).

This project is intentionally simple: Bash scripts plus service config files. No VPN, no heavy daemon.

## Documentation

- `docs/case-study-openai.md` - real troubleshooting history (symptoms -> root cause -> fix)
- `docs/faq.md` - practical Q&A
- `docs/migration.md` - migration from older home-directory scripts
- `docs/roadmap-watchlist.md` - future ideas
- `CONTRIBUTING.md` - contribution guide
- `SECURITY.md` - security policy
- `DISCLAIMER.md` - policy and liability notes

## What It Does

Typical setup:
- `en7` Ethernet is your default route
- `en0` hotspot is used only for selected services

`splitroute` does two things:

1. **Per-host routes (route by IP)**
- Resolve hostnames from `services/<service>/hosts.txt`
- Add host routes so those IPs use the hotspot gateway

2. **Per-domain DNS override (optional but default ON)**
- Write `/etc/resolver/<domain>` files for domains in `services/<service>/dns_domains.txt`
- Helps bypass DNS-based blocking (for example `146.112.61.x` blocked-page answers)

This is **not** a VPN. It does not tunnel all traffic.

## Security

- No MITM/proxy logic
- No certificate installation
- No TLS verification disable
- HTTPS remains end-to-end encrypted

The tool changes:
- host routes in the routing table
- managed resolver files in `/etc/resolver`

## Requirements

- macOS
- admin permissions (`sudo`) for `route` and `/etc/resolver`
- standard tools: `route`, `netstat`, `ifconfig`, `ipconfig`, `dscacheutil`, `curl`
- optional tools: `dig`, `lsof`

## Project Layout

- `bin/splitroute` - CLI entrypoint
- `scripts/splitroute_on.sh` - enable routing for a service
- `scripts/splitroute_off.sh` - disable routing and clean state
- `scripts/splitroute_check.sh` - diagnostics
- `services/<service>/hosts.txt` - hosts (one per line)
- `services/<service>/dns_domains.txt` - resolver domains (base domains only)
- `services/_template/` - service template

Default service: `openai`.

## Quick Start

1. Connect both links:
   - Ethernet (default route)
   - hotspot on Wi-Fi

2. Enable split-routing:
```bash
cd /path/to/splitroute
./bin/splitroute on openai
```

3. Verify routing:
```bash
./bin/splitroute check openai -- --host chatgpt.com --control
```

4. Refresh if needed:
```bash
./bin/splitroute refresh openai
```

5. Turn it off:
```bash
./bin/splitroute off openai
```

## Configuration

### Interfaces

Defaults:
- `WIFI_IF=en0`
- `ETH_IF=en7`

Override example:
```bash
WIFI_IF=en0 ETH_IF=en7 ./bin/splitroute check openai -- --control
```

### Host list

Edit:
- `services/openai/hosts.txt`

### DNS override

Modes:
- `DNS_OVERRIDE=on` - always use per-domain resolvers
- `DNS_OVERRIDE=auto` - enable only when blocked DNS is detected
- `DNS_OVERRIDE=off` - never write `/etc/resolver`

Default:
- `DNS_OVERRIDE=on`

Examples:
```bash
DNS_OVERRIDE=on DNS_SERVERS="1.1.1.1 8.8.8.8" ./bin/splitroute on openai
```

Domain source:
- `services/openai/dns_domains.txt`

## Diagnostics

Routing check:
```bash
./bin/splitroute check openai -- --no-curl
```

Control host check:
```bash
./bin/splitroute control openai -- --control-host youtube.com --no-curl
```

PID-based check:
```bash
pgrep -n codex
./bin/splitroute check openai -- --pid <PID> --no-curl
```

## Persistence and Cleanup

- Host routes are runtime-only and disappear after reboot.
- Resolver files in `/etc/resolver` are on-disk and can persist until cleaned.
- `./bin/splitroute off <service>` removes both routes and managed resolver files.
- `splitroute_off.sh` has fallback cleanup even when `/tmp` state files are gone.

Menu bar app behavior:
- Auto-OFF is intentionally removed.
- ON/OFF are manual only.
- At app launch, stale splitroute state from a previous session is detected and reset (requires admin auth).
- Service host files are never auto-deleted. They stay in `services/<service>/` until you remove them manually.

To guarantee reset after reboot/login, add the app to macOS Login Items so startup cleanup runs automatically.

## Limitations

1. Routing is by IP, not by domain.
2. CDN IPs can rotate; use `refresh` when needed.
3. IPv6 may be unavailable on hotspot.
4. If hotspot disconnects while ON, service traffic can fail until `off` or `refresh`.

## Roadmap

- Better service editor UX
- Optional blocked-service watchlist
- Optional helper/daemon model for stricter lifecycle cleanup

## Menu Bar App (local build)

Build and run:
```bash
bash scripts/build_menubar_app.sh
open build/SplitrouteMenuBar.app
```

Workflow:
```bash
bash scripts/workflow_menubar_app.sh
# or install to /Applications
sudo bash scripts/workflow_menubar_app.sh
```

Package:
```bash
bash scripts/package_menubar_app.sh
open build/SplitrouteMenuBar.dmg
```

If DMG creation fails, the script creates `build/SplitrouteMenuBar.zip`.

## Release Workflow

1. Build/install/package:
```bash
sudo bash scripts/workflow_menubar_app.sh
```

2. Commit and tag:
```bash
git commit -am "release: v0.x"
git tag -a v0.x -m "v0.x"
```

3. Push:
```bash
git push origin master --tags
```

4. Create release:
```bash
gh release create v0.x build/SplitrouteMenuBar.dmg -t "v0.x" -n "Release v0.x"
```

If DMG is missing:
```bash
gh release create v0.x build/SplitrouteMenuBar.zip -t "v0.x" -n "Release v0.x"
```

## Notes

- If repo auto-detection fails, use `Settings -> Set Repo Path...`.
- `Services` supports multi-select.
- `Check connections` verifies route behavior without changing config.
- `Add Service...` can create a basic service or run Smart Host Discovery (explicit opt-in).
- `Touch ID (sudo)` requires `pam_tid.so` in `/etc/pam.d/sudo`.
