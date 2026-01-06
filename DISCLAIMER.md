# Disclaimer

`splitroute` is a local macOS networking tool. It can modify:
- the system routing table (per‑IP host routes), and
- per‑domain DNS resolvers under `/etc/resolver/` (enabled by default).

It requires administrator privileges (`sudo`).

Use at your own risk.

## No warranty / limitation of liability

To the maximum extent permitted by applicable law:
- This software is provided "AS IS", without warranty of any kind.
- In no event shall the authors or copyright holders be liable for any claim, damages, or other liability.

For the full legal text, see `LICENSE`.

## Policy / compliance

- This tool can bypass DNS‑based filtering on some networks for selected domains (e.g. corporate DNS policies, parental controls).
- You are responsible for complying with your device and network policies, and for ensuring you are authorized to use such configuration.

## Privacy / security notes (plain language)

- This tool does not install certificates and does not set a proxy, so it does not intentionally enable MITM.
- HTTPS/TLS traffic remains encrypted end‑to‑end to the destination server.
- DNS queries for selected domains may be sent to the configured DNS resolvers (e.g. a hotspot gateway and/or public DNS).
- Routing selected services over a hotspot can incur data charges and can expose metadata to your mobile carrier (as with any hotspot usage).

## How to revert changes

- Run `./bin/splitroute off <service>` to remove routes and managed `/etc/resolver` entries.
- If you reboot while splitroute is ON, `/etc/resolver` files may remain; running `off` will clean them up.

## Trademarks / affiliation

Apple, macOS, iPhone, OpenAI, ChatGPT, Cloudflare, and Cisco are trademarks of their respective owners.
This project is not affiliated with, endorsed by, or sponsored by them.
