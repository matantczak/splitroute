# Security policy

## Supported versions

This project is a collection of local scripts for macOS. There is no formal support window.

## Reporting a vulnerability

If you believe you found a security issue in this repo:
- Prefer opening a **private** report via your Git hosting platform if available.
- Otherwise, open an issue with minimal details and ask for a private contact channel.

Please include:
- what you ran (command line),
- what you expected,
- what happened,
- your macOS version and network setup (no secrets/tokens).

Notes:
- There is no security bounty program and no response-time guarantee.
- Do not include credentials, tokens, cookies, or private logs in reports.

## What this project does (and does not) do

This project:
- adds/removes per‑IP host routes for a selected service,
- can write per‑domain resolvers under `/etc/resolver/` for selected domains (enabled by default; configurable),
- never installs certificates, never sets proxy settings, and never disables TLS verification.

Threat model notes:
- it can be used to bypass DNS‑based filtering present on a network (e.g. corporate DNS policies) for selected domains,
- it does not protect you from malicious networks by itself (it is not a VPN),
- it does not provide anonymity.

## Operational safety notes

- The `on/off` scripts run with `sudo`. Review the scripts before running them on your machine.
- The only on‑disk system changes are files written under `/etc/resolver/` that contain a marker (`splitroute_managed:<service>`).
- Runtime state files are stored under `/tmp/`.
- If you do not want the tool to write anything to `/etc/resolver/`, run with `DNS_OVERRIDE=off`.
