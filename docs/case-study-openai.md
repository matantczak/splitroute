# Case Study: OpenAI/ChatGPT/Codex Split Routing on macOS

This note captures the real troubleshooting path and final architecture used for OpenAI traffic split-routing.

## Goal

With both links active:
- `en7` Ethernet as default route
- `en0` iPhone hotspot on Wi-Fi

we want:
- normal internet via Ethernet
- OpenAI-related traffic via hotspot
- simple ON/OFF behavior
- no TLS weakening and no MITM.

## Symptoms

With Ethernet connected:
- Codex CLI was unstable
- browser sometimes failed to open `https://chatgpt.com/`
- route checks could show `en0`, yet requests still failed

Strong signal:
- `curl` showed certificate trust errors in some paths.

## Root Cause

The primary issue was DNS, not host-route mechanics.
Some queries resolved to blocked-page IPs (for example `146.112.61.x`, commonly associated with Cisco Umbrella/OpenDNS policies).

So traffic was routed correctly to the wrong destination IP.

## Working Fix

Two combined layers fixed it:

1. **Host routes by IP**
- Resolve A/AAAA from `services/openai/hosts.txt`
- Add host routes toward hotspot gateway

2. **Per-domain DNS override**
- Write managed files in `/etc/resolver/<domain>`
- Source domains from `services/openai/dns_domains.txt`
- Use hotspot gateway first, then public DNS fallback

This removed blocked DNS answers and restored correct TLS behavior.

## Minimal Validation Set

1. Default route sanity:
```bash
netstat -rn -f inet | head -n 6
```

2. Resolver output sanity:
```bash
dscacheutil -q host -a name chatgpt.com
```

3. Interface decision for target IP:
```bash
route -n get <target_ip> | rg -n "gateway:|interface:"
```

4. Split vs control routing:
```bash
./bin/splitroute check openai -- --host chatgpt.com --control --no-curl
```

5. HTTPS probe:
```bash
./bin/splitroute check openai -- --host chatgpt.com
```

## Safety Model

The tool does **not**:
- install certificates
- set system proxy
- perform MITM
- disable TLS verification

It only changes routing entries and managed resolver files.

## Practical Constraints

1. Routing is IP-based, not domain-native.
2. CDN IP rotation requires refresh.
3. IPv6 depends on hotspot capabilities.
4. Resolver files can persist until cleanup.
