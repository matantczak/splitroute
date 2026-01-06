# Contributing

Thanks for considering a contribution!

## Scope

This project focuses on:
- simple, auditable macOS scripts (no VPN, no proxy/MITM),
- predictable ON/OFF behavior,
- per‑service configuration via `services/<service>/`.

## Adding a new service

1) Create a new service directory:
```bash
cp -R services/_template services/<service>
```
or:
```bash
./bin/splitroute new-service <service>
```

2) Edit the files:
- `services/<service>/hosts.txt` — FQDNs used by the service (one per line)
- `services/<service>/dns_domains.txt` — base domains for `/etc/resolver` (one per line, no subdomains)

Rule of thumb:
- if you add `api.example.com` to `hosts.txt`, add `example.com` to `dns_domains.txt`.

3) Run it:
```bash
./bin/splitroute on <service>
./bin/splitroute check <service> -- --control --no-curl
```

## Testing changes

Minimum:
```bash
bash -n bin/splitroute scripts/*.sh
```

Functional checks (manual):
- `./bin/splitroute on <service>`
- `./bin/splitroute check <service> -- --control`
- `./bin/splitroute off <service>`

## Please avoid

- Adding anything that disables TLS verification.
- Adding proxy/MITM logic or certificate installation.
- Committing logs, tokens, or credentials (including HTTP headers).
