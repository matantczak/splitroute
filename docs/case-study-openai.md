# Case study: OpenAI/ChatGPT/Codex split‑routing on macOS

Ten dokument zapisuje „historię problemu” i wnioski z konfiguracji split‑routingu dla usług OpenAI na macOS.
Powstał jako notatka utrwalająca kontekst diagnostyczny (żeby dało się to rozwijać i łatwo wrócić do rozumowania po przerwie).

## Cel

Gdy jednocześnie aktywne są:
- `en7` — Ethernet (dock) **jako domyślna trasa**,
- `en0` — Wi‑Fi hotspot (iPhone),

to:
- cały „zwykły internet” ma iść przez Ethernet (`en7`),
- ale ruch do OpenAI/ChatGPT/Codex ma iść przez hotspot (`en0`),
- ma być łatwe ON/OFF i sprzątanie stanu,
- bez VPN i bez obniżania bezpieczeństwa TLS.

## Objawy

Przy wpiętym Ethernecie (domyślna trasa na `en7`):
- Codex CLI w terminalu nie działał poprawnie,
- przeglądarka czasem też nie otwierała `https://chatgpt.com/`,
- mimo że host‑route dla `chatgpt.com` (IPv4) potrafił wskazywać interfejs `en0`.

Kluczowy sygnał diagnostyczny:
- `curl` zwracał `SSL certificate problem: unable to get local issuer certificate` nawet przy próbie przez `--interface en0`.

## Co się okazało (przyczyna)

Problemem nie był sam routing, tylko **DNS** w sieci po Ethernecie:
- domeny (`chatgpt.com`, `api.openai.com`) rozwiązywały się do adresów typu `146.112.61.x`,
- taki zakres jest często używany przez **Cisco Umbrella/OpenDNS** jako „blocked page”,
- wtedy klient HTTPS trafia nie w prawdziwy endpoint (np. Cloudflare/OpenAI), tylko w stronę blokady,
  co potrafi kończyć się błędem weryfikacji certyfikatu.

Wniosek: jeśli DNS jest „podmieniony”, to nawet poprawne host‑route’y mogą kierować do „złego” IP.

## Rozwiązanie (co faktycznie naprawiło sytuację)

W tej wersji projektu zrobiono dwa elementy:

1) **Routing po IP (host routes)** dla domen z `services/openai/hosts.txt`:
- resolve A/AAAA → IP,
- `route add -inet -host <ip> <GW_hotspot>` (nieskopowane, działa dla normalnych socketów),
- opcjonalnie IPv6, jeśli hotspot ma wykrywalny IPv6 gateway.

2) **Per‑domain DNS override** dla domen z `services/openai/dns_domains.txt`, gdy wykryto typowe oznaki blokady DNS:
- tworzone są pliki `/etc/resolver/<domain>` z markerem `splitroute_managed:openai`,
- jako DNS wpisywany jest najpierw gateway hotspota, a potem publiczny fallback (domyślnie `1.1.1.1` i `1.0.0.1`),
- po zmianie wykonywany jest flush cache DNS.

Właśnie ten drugi element (per‑domain resolver) był kluczowy dla usunięcia `146.112.61.x` i przywrócenia poprawnego TLS.

## Jak to potwierdzaliśmy (minimalny zestaw testów)

### 1) Sprawdzenie domyślnej trasy
```bash
netstat -rn -f inet | head -n 6
```
Oczekiwane: `default ... en7` (Ethernet jako default).

### 2) Sprawdzenie, jakie IP daje systemowy resolver
```bash
dscacheutil -q host -a name chatgpt.com
```
Oczekiwane: IP Cloudflare (np. `104.18.x.x` / `172.64.x.x`), **nie** `146.112.61.x`.

### 3) Sprawdzenie interfejsu, którym system pójdzie do IP
```bash
route -n get 104.18.32.47 | rg -n "gateway:|interface:"
```
Oczekiwane: `interface: en0` dla IP OpenAI/ChatGPT objętych split‑routingiem.

### 4) Test „czy reszta internetu idzie domyślnie”
`splitroute_check.sh` ma tryb kontrolny:
```bash
./bin/splitroute check openai -- --host chatgpt.com --control --no-curl
```
Oczekiwane:
- hosty OpenAI → `route_if=en0`,
- host kontrolny (np. `example.com`/`youtube.com`) → `route_if` taki jak domyślna trasa (zwykle `en7`).

### 5) Szybki probe HTTPS (bez nagłówków/tokens)
```bash
./bin/splitroute check openai -- --host chatgpt.com
```
Oczekiwane: brak błędu certyfikatu, a `tls_verify=0` (czyli weryfikacja certyfikatu OK).

Uwaga: `http=403` dla `https://chatgpt.com/` w `curl` jest normalne (Cloudflare/ochrona).
Nie testujemy tu logowania ani sesji użytkownika — tylko to, że TLS i routing działają.

## Dlaczego to jest bezpieczne

Ten projekt:
- nie instaluje żadnych certyfikatów,
- nie używa proxy MITM,
- nie ustawia systemowych proxy,
- nie wyłącza weryfikacji TLS (nie używa `curl -k`).

Zmienia tylko:
- tablicę routingu (host‑route’y),
- opcjonalnie per‑domenowe resolvery DNS w `/etc/resolver`.

## Ograniczenia, które wyszły w praktyce

1) **CDN/IP rotacja**: IP mogą się zmieniać (TTL DNS, load‑balancing).
   - jeśli coś przestaje działać, użyj `splitroute refresh openai`.
2) **IP współdzielone (CDN)**: routing po IP może w rzadkich przypadkach „zabrać” też niepowiązany ruch do tego samego IP.
3) **IPv6**: hotspot często nie daje IPv6 gateway → AAAA mogą mieć status `NO_V6_ON_en0`.
4) **/etc/resolver po restarcie**: routy znikają, ale pliki resolver mogą zostać, jeśli nie wykonasz `off` przed restartem (patrz README).

