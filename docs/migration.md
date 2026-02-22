# Migration from Home Scripts to `splitroute`

This guide helps migrate from old files in your home directory, for example:
- `~/openai_on.sh`
- `~/openai_off.sh`
- `~/openai_check.sh`
- `~/openai_hosts.txt`

to the repository-based workflow in `splitroute`.

## Why migration needs care

If Ethernet-side DNS is filtered/rewritten (for example to `146.112.61.x`), switching tools can briefly interrupt access until the new setup is enabled.

## Before You Start

1. Open this file locally so you can follow it offline.
2. Verify the new repo works:
```bash
cd /path/to/splitroute
./bin/splitroute list
./bin/splitroute help
```

## Path A (recommended): no access gap

1. Disconnect Ethernet temporarily, keep hotspot connected.
2. Disable old mode:
```bash
sudo ~/openai_off.sh
```
3. Enable new mode:
```bash
cd /path/to/splitroute
./bin/splitroute on openai
```
4. Optional quick check:
```bash
./bin/splitroute check openai -- --host chatgpt.com --control --no-curl
```
5. Reconnect Ethernet and verify:
```bash
./bin/splitroute check openai -- --host chatgpt.com --control
```
6. If blocked DNS appears (`146.112.61.x`) or cert errors show up:
```bash
DNS_OVERRIDE=on ./bin/splitroute refresh openai
```

## Path B: live switch (may cause short gap)

Prepare and run quickly:
```bash
sudo ~/openai_off.sh
cd /path/to/splitroute && ./bin/splitroute on openai
```

Then verify:
```bash
cd /path/to/splitroute && ./bin/splitroute check openai -- --host chatgpt.com --control
```

## Post-Migration Cleanup

1. Verify new OFF path:
```bash
cd /path/to/splitroute && ./bin/splitroute off openai
```

2. Check old resolver artifacts:
```bash
sudo grep -R "openai_splitrouting_managed" /etc/resolver 2>/dev/null || true
```

3. If anything remains, run old cleanup once:
```bash
sudo ~/openai_off.sh
```

4. Remove old home scripts when comfortable.

## Emergency Recovery

Fast path:
```bash
cd /path/to/splitroute && ./bin/splitroute refresh openai
```

If DNS rewriting is suspected:
```bash
cd /path/to/splitroute && DNS_OVERRIDE=on ./bin/splitroute refresh openai
```
