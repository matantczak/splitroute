# Service template

This folder is a starter for defining a new service.

- `hosts.txt` contains the hostnames (FQDN) used by the service.
- `dns_domains.txt` contains the base domains that should get a per‑domain resolver in `/etc/resolver`.

Create a new service by copying this directory:
```bash
cp -R services/_template services/<service>
```

