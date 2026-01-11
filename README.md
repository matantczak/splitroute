# splitroute (macOS)

Narzędzie do **split‑routingu** na macOS: ustawiasz, że **domyślny ruch** idzie jednym interfejsem (np. Ethernet), a **wybrane usługi** (np. OpenAI/ChatGPT/Codex) są kierowane innym interfejsem (np. iPhone hotspot).

Projekt jest celowo „lekki”: to zestaw skryptów Bash + pliki konfiguracyjne (listy domen). Nie wymaga VPN ani ciężkich aplikacji.

## Dokumentacja

- `docs/case-study-openai.md` — pełny kontekst diagnostyczny (objawy → przyczyna → rozwiązanie)
- `docs/faq.md` — odpowiedzi na typowe pytania (bezpieczeństwo, „czy tylko OpenAI idzie przez hotspot?”, IP rotacja)
- `docs/migration.md` — checklist migracji ze starych plików w `~` na to repo (jeśli używałeś „home scripts”)
- `CONTRIBUTING.md` — jak dodać nową usługę i testować zmiany
- `SECURITY.md` — informacje bezpieczeństwa i zgłaszanie podatności
- `DISCLAIMER.md` — uwagi dot. polityk sieci i odpowiedzialności

## Po co to jest

Typowy przypadek:
- masz dwa łącza jednocześnie:
  - `en7` = Ethernet (dock) — szybkie/stabilne, ma być domyślne,
  - `en0` = Wi‑Fi hotspot (iPhone) — chcesz, żeby **tylko** wybrane usługi szły tędy,
- chcesz szybko włączać/wyłączać reguły (ON/OFF),
- chcesz uniknąć proxy/MITM i nie psuć TLS.

## Jak to działa (w skrócie)

`splitroute` robi dwie rzeczy (zależnie od sytuacji):

1) **Per‑host routes (routing po IP)**
- Skrypt rozwiązuje domeny z `services/<service>/hosts.txt` do listy IP (A/AAAA),
- Dodaje **host‑route’y** dla tych IP tak, aby system wysyłał ruch do tych IP przez bramę hotspota (`en0`).
- Dzięki temu nawet jeśli domyślna trasa jest na Ethernecie (`en7`), to ruch do tych konkretnych IP pójdzie przez hotspot.

2) **Per‑domain DNS override (opcjonalnie)**
- Jeśli DNS „po drodze” jest blokowany/„podmieniany” (np. Cisco Umbrella/OpenDNS), domeny typu `chatgpt.com` mogą rozwiązywać się do IP strony blokady (często `146.112.61.x`), co kończy się m.in. błędami certyfikatu.
- W takiej sytuacji `splitroute` może założyć pliki w `/etc/resolver/<domain>` dla wybranych domen (z `services/<service>/dns_domains.txt`), aby te domeny były rozwiązywane przez inne serwery DNS (domyślnie: gateway hotspota, a potem 1.1.1.1/1.0.0.1).

To nie jest VPN: nie tuneluje całego ruchu. Dodaje tylko konkretne wpisy routingu i (opcjonalnie) per‑domenowe resolvery DNS.

## Bezpieczeństwo (ważne)

- **Nie ma MITM/proxy**: projekt nie wstrzykuje certyfikatów, nie zmienia keychain, nie ustawia żadnych proxy systemowych.
- **TLS pozostaje TLS**: połączenia HTTPS nadal są szyfrowane end‑to‑end do serwera docelowego. Weryfikacja certyfikatu jest po stronie klienta (np. `curl`, przeglądarka, Codex).
- `splitroute_check.sh` pokazuje `tls_verify=0` wtedy, gdy weryfikacja certyfikatu **się udała** (`ssl_verify_result == 0` w `curl`).

Uwaga: jeśli Twoja sieć (Ethernet) sama w sobie robi MITM (np. firmowy proxy z własnym CA), to jest to cecha środowiska sieciowego — `splitroute` tego nie instaluje ani nie wymusza. W praktyce split‑routing może wręcz pomagać omijać takie środowisko dla wybranych usług, kierując je przez hotspot.

## Wymagania

- macOS (testowane ad‑hoc na aktualnych wersjach)
- uprawnienia admina (komendy `route` i `/etc/resolver` wymagają `sudo`)
- standardowe narzędzia: `route`, `netstat`, `ifconfig`, `ipconfig`, `dscacheutil`, `curl`, opcjonalnie `dig`, `lsof`

## Struktura projektu

- `bin/splitroute` — prosta komenda sterująca (on/off/refresh/check)
- `scripts/splitroute_on.sh` — włącza split‑routing dla usługi
- `scripts/splitroute_off.sh` — wyłącza i sprząta (routy + resolvery DNS)
- `scripts/splitroute_check.sh` — diagnostyka: routing, DNS, (opcjonalnie) curl, (opcjonalnie) PID connections
- `services/<service>/hosts.txt` — lista hostów dla danej usługi (jeden na linię)
- `services/<service>/dns_domains.txt` — lista domen (nie subdomen!) do `/etc/resolver` (jeden na linię)
- `services/_template/` — szablon do tworzenia nowej usługi

Domyślna usługa: `openai`.

## Szybki start (OpenAI/ChatGPT/Codex)

### Instalacja (repo gdziekolwiek)

Umieść repo w dowolnym katalogu (np. przez `git clone`), a potem uruchamiaj polecenia z katalogu repo.

1) Podłącz oba łącza:
   - Ethernet (np. `en7`) jako domyślne,
   - hotspot iPhone na Wi‑Fi (zwykle `en0`).

2) Włącz split‑routing dla OpenAI:
```bash
cd /path/to/splitroute
./bin/splitroute on openai
```

3) Sprawdź, czy OpenAI idzie przez hotspot, a „kontrolny” host idzie trasą domyślną:
```bash
./bin/splitroute check openai -- --host chatgpt.com --control
```

4) Jeśli coś przestaje działać (zmiana IP przez CDN/load‑balancing) — odśwież:
```bash
./bin/splitroute refresh openai
```

5) Wyłącz i wróć do normalnego zachowania macOS:
```bash
./bin/splitroute off openai
```

## Konfiguracja

### Interfejsy

Domyślnie:
- `WIFI_IF=en0`
- `ETH_IF=en7`

Jeśli masz inne nazwy:
```bash
WIFI_IF=en0 ETH_IF=en7 ./bin/splitroute check openai -- --control
```

### Lista hostów usługi

Edytuj: `services/openai/hosts.txt`

Możesz dopisywać hosty, z których realnie korzysta klient (np. `api.openai.com`, `auth.openai.com`, `oaistatic.com`, `oaiusercontent.com`).

### DNS override (/etc/resolver)

Skrypty mają tryb:
- `DNS_OVERRIDE=on` — zawsze włącz override
- `DNS_OVERRIDE=auto` — włącza override, jeśli wykryje typowy „blocked page” IP (`146.112.61.x`) dla hostów z listy usługi
- `DNS_OVERRIDE=off` — nigdy nie ruszaj `/etc/resolver`

Domyślnie:
- `DNS_OVERRIDE=on` dla wszystkich usług (żeby nie „wracała” blokada DNS po zmianie sieci).

Jeśli chcesz nadpisać domyślne zachowanie bez podawania `DNS_OVERRIDE` za każdym razem, użyj:
- `DNS_OVERRIDE_DEFAULT=auto` / `DNS_OVERRIDE_DEFAULT=off`

Serwery DNS (fallback) ustawisz np.:
```bash
DNS_OVERRIDE=on DNS_SERVERS="1.1.1.1 8.8.8.8" ./bin/splitroute on openai
```

Domeny, dla których tworzone są pliki w `/etc/resolver`, są w:
- `services/openai/dns_domains.txt`

Ważne: celowo **nie** dodajemy tu `cloudflare.com`, żeby nie zmieniać DNS dla ogromnej liczby niepowiązanych usług.

## Diagnostyka i testy

### 1) Status routingu dla hostów usługi
```bash
./bin/splitroute check openai -- --no-curl
```

### 2) Test kontrolny „czy reszta internetu idzie domyślnie”
```bash
./bin/splitroute control openai -- --control-host youtube.com --no-curl
```

### 3) Sprawdzenie ruchu konkretnego procesu (np. Codex)
1) Uruchom Codex w osobnym terminalu.
2) Znajdź PID (przykład):
```bash
pgrep -n codex
```
3) Sprawdź połączenia procesu:
```bash
./bin/splitroute check openai -- --pid <PID> --no-curl
```

### 4) Typowy objaw problemu z DNS (Umbrella/OpenDNS)

Jeśli widzisz w rozwiązywaniu DNS IP typu `146.112.61.x` albo `curl`/przeglądarka krzyczy o certyfikaty, to zwykle **nie routing**, tylko **DNS podmieniony na stronę blokady**.

Wtedy:
- włącz `DNS_OVERRIDE=on` i uruchom `on`/`refresh`,
- zweryfikuj, że `dig +short @1.1.1.1 chatgpt.com` zwraca IP inne niż `146.112.61.x`.

## „Bez śladów” i zachowanie po restarcie

- Host‑route’y dodane przez `route add ...` są w pamięci i **znikają po restarcie**.
- Pliki `/etc/resolver/*` są na dysku, więc jeśli zrestartujesz komputer w trybie ON (bez `off`), to te pliki mogą zostać i dalej wpływać na DNS dla tych domen.

Co robimy w tej wersji:
- `splitroute off` usuwa zarówno routy, jak i pliki `/etc/resolver` stworzone przez narzędzie,
- `splitroute_off.sh` ma fallback: jeśli `/tmp` zniknęło po restarcie, i tak usuwa wszystkie pliki z markerem `splitroute_managed:<service>`.

Plany na przyszłość (świadomie **nie** w tej wersji):
- LaunchDaemon/helper, który przy starcie systemu sprząta `/etc/resolver`, jeśli tryb nie jest aktywny (czyli „zawsze czysto po restarcie” bez ręcznego `off`).

## Ograniczenia (ważne, żeby rozumieć)

1) Routing jest **po IP**, a nie „po domenie”.
   - Jeśli CDN współdzieli IP między różnymi usługami, bardzo rzadko może to spowodować, że jakiś niepowiązany ruch do tego samego IP też pójdzie przez hotspot.

2) IP usług mogą się zmieniać (CDN/load‑balancing).
   - Jeśli w trakcie sesji pojawią się nowe IP, których nie ma w trasach, część nowych połączeń może wrócić na domyślną trasę.
   - Rozwiązanie w tej wersji: `splitroute refresh`.

3) IPv6:
   - Hotspot iPhone często nie daje IPv6 routingu; wtedy AAAA może wskazywać IP, do którego nie da się sensownie dodać trasy przez `en0`.
   - Skrypty dodają IPv6 host‑route’y tylko jeśli wykryją IPv6 gateway na `WIFI_IF`.

4) Hotspot rozłączy się w trybie ON:
   - host‑route’y mogą dalej wskazywać bramę hotspota, która nie istnieje → część połączeń do usługi może przestać działać,
   - w tej wersji trzeba ręcznie wykonać `splitroute off` (lub ponownie podłączyć hotspot i zrobić `refresh`).

## Roadmap (kierunek rozwoju)

- prosta aplikacja menu‑bar (SwiftUI) z przyciskami: ON/OFF/REFRESH/STATUS
- edytor usług (dodawanie folderów w `services/`)
- opcjonalny tryb „auto‑refresh” (np. co 15 min lub przy zmianie sieci)
- tryb „always clean after reboot” (LaunchDaemon/helper)

## Menu‑bar app (lokalnie)

W repo jest prosta aplikacja menu‑bar `SplitrouteMenuBar` (AppKit), która steruje skryptami `splitroute` z górnego paska macOS.

Build + uruchomienie:
```bash
bash scripts/build_menubar_app.sh
open build/SplitrouteMenuBar.app
```

Workflow (po zmianach: build + install + uruchom + paczka):
```bash
bash scripts/workflow_menubar_app.sh
# lub (jesli chcesz instalowac do /Applications)
sudo bash scripts/workflow_menubar_app.sh
```

Pakowanie do DMG (instalacja przez przeciagniecie do Applications):
```bash
bash scripts/package_menubar_app.sh
open build/SplitrouteMenuBar.dmg
```
Jeśli DMG nie da sie zrobic, skrypt stworzy `build/SplitrouteMenuBar.zip` (instalacja: rozpakuj i przeciagnij appke do Applications).

Uwagi:
- Jeśli appka nie wykryje automatycznie repo, użyj `Set Repo Path…`.
- `Services` pozwala zaznaczyć wiele usług naraz; `ON/OFF/REFRESH/STATUS/VERIFY` działają na zaznaczone.
- `Services -> Add Service…` tworzy nową usługę na podstawie domeny i od razu ją włącza.
- `Auth -> Touch ID (sudo)` działa, gdy Touch ID jest włączone dla `sudo` (w `/etc/pam.d/sudo` jest `pam_tid.so`). W przeciwnym razie wybierz `Password prompt (system dialog)`.
- Auto‑OFF po uśpieniu wykona się po wybudzeniu (może poprosić o autoryzację).
- Po przełączeniu `ON/OFF` przeglądarka może trzymać istniejące połączenia — do testów zrób pełne wyjście (`Cmd+Q`) albo użyj `STATUS/VERIFY`.
- Żeby mieć ją „jak normalną appkę”: skopiuj do `~/Applications/` albo zainstaluj do `/Applications/` przez `bash scripts/install_menubar_app.sh` (może wymagać `sudo`), a potem dodaj do Login Items.

## Publikacja na GitHub

Przed publikacją warto:
- zweryfikować `LICENSE` (np. jeśli chcesz inną licencję niż MIT),
- dopisać informacje o wersji macOS i znanych ograniczeniach sieci (firmowe DNS, proxy).

## License

MIT — see `LICENSE`.
