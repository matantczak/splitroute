# FAQ

## Is this safe? Does HTTPS stay encrypted?
Yes. HTTPS/TLS remains end-to-end encrypted. This project does not install certificates and does not perform MITM.

## How can I verify certificate validation is enabled?
In `splitroute_check.sh`, the HTTPS probe reports `tls_verify`.
For `curl`, `tls_verify=0` means certificate verification succeeded (`ssl_verify_result == 0`).

## Can I be sure only selected services go through hotspot?
This implementation routes by IP. It adds host routes only for IPs resolved from each service host list.
Most traffic still follows your default route; selected service IPs follow hotspot routes.

Rare edge case: if a CDN IP is shared by multiple products, another service on the same IP may also use hotspot.

## Do service IPs change?
Yes. CDN-backed services can rotate IPs.
When routing starts to degrade, run:
```bash
./bin/splitroute refresh <service>
```

## Why is DNS override sometimes needed?
Some networks return blocked-page DNS responses (for example `146.112.61.x` from Umbrella/OpenDNS).
In that case routing can look correct but still point to wrong destination IPs.
Per-domain resolvers under `/etc/resolver` solve this for selected domains.

## Why do I sometimes need refresh after connecting Ethernet?
If DNS context changes after network switch, newly resolved IPs can differ.
Use:
```bash
DNS_OVERRIDE=on ./bin/splitroute refresh <service>
```

## Does splitroute leave anything after reboot?
- Host routes disappear on reboot.
- `/etc/resolver` files are on disk until cleaned.
- `splitroute off` cleans routes and managed resolver files.
- The menu bar app now resets stale splitroute state at startup (admin auth required).

## What happens if hotspot disconnects while ON?
Static routes can point to an unavailable gateway and service traffic may fail.
Fix:
```bash
./bin/splitroute off <service>
```
or reconnect hotspot and run `refresh`.

## Do you automatically delete my saved hosts/services?
No. Service files under `services/<service>/` are never auto-deleted by ON/OFF/restart cleanup.
You delete them only manually.

## Why can browser traffic still work briefly after OFF?
Browsers may keep existing connections alive (HTTP/2, WebSocket, QUIC).
To test cleanly:
- run `off`
- fully quit browser (`Cmd+Q`)
- reopen and test again

## Does this work with Codex CLI and browsers?
Yes, that is the intended use case.
If behavior differs between links, DNS policy on the Ethernet side is usually the main cause.
