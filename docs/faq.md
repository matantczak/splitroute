# FAQ

## Czy to jest bezpieczne? Czy HTTPS nadal jest szyfrowany?
Tak: HTTPS/TLS nadal działa end‑to‑end. Ten projekt nie instaluje certyfikatów i nie robi MITM.
Zmieniamy tylko routing (host‑route’y) oraz opcjonalnie per‑domenowy DNS resolver (/etc/resolver), żeby domeny rozwiązywały się do poprawnych IP.

## Skąd wiem, że weryfikacja certyfikatu jest włączona?
W `splitroute_check.sh` w sekcji `HTTPS probes` jest pole `tls_verify`.
W `curl` wartość `0` oznacza sukces weryfikacji (`ssl_verify_result == 0`).

## Czy mam pewność, że tylko OpenAI idzie przez hotspot, a reszta przez Ethernet?
W tej implementacji routing jest **po IP**: dodajemy host‑route’y tylko dla IP rozwiązywanych z listy domen usługi.
To oznacza, że „zwykły ruch” idzie dalej trasą domyślną (np. Ethernet), a ruch do tych konkretnych IP pójdzie przez hotspot.

Uwaga praktyczna: jeśli CDN współdzieli IP między usługami, to bardzo rzadko może się zdarzyć, że inna usługa korzystająca z tego samego IP też poleci przez hotspot. To ograniczenie podejścia „route by IP”.

## Czy te IP mogą się zmienić?
Tak. Serwisy za CDN (np. Cloudflare) mogą zmieniać IP w czasie.
Jeśli w trakcie sesji pojawią się nowe IP, których nie ma w dodanych trasach, część nowych połączeń może wrócić na domyślną trasę.
Dlatego jest `Refresh`:
- `./bin/splitroute refresh openai` (odświeża resolve i trasy)

## Dlaczego czasem potrzebny jest DNS override (/etc/resolver)?
Bo niektóre sieci (często firmowe) podmieniają odpowiedzi DNS dla wybranych domen, np. na stronę blokady (typowo `146.112.61.x` dla Cisco Umbrella/OpenDNS).
Wtedy nawet poprawny routing prowadzi do „złego” IP, a TLS może failować.
Per‑domain resolvery pozwalają rozwiązywać tylko wybrane domeny przez inny DNS.

## Dlaczego czasem trzeba zrobić `refresh` po podpięciu Ethernetu?
Domyślnie używamy `DNS_OVERRIDE=on`, więc zwykle problem nie występuje.
Jeśli jednak uruchomisz usługę z `DNS_OVERRIDE=auto` albo `DNS_OVERRIDE=off`, to pamiętaj że po podpięciu Ethernetu systemowy DNS może się zmienić (i np. zacząć zwracać `146.112.61.x`).
Wtedy zrób:
- `DNS_OVERRIDE=on ./bin/splitroute refresh openai`

## Czy to zostawia „ślady” po restarcie?
- Host‑route’y znikają po restarcie same.
- Pliki `/etc/resolver/*` są na dysku i mogą zostać, jeśli zrestartujesz komputer w trybie ON bez `off`.
W tej wersji `splitroute off` sprząta wszystko, a `splitroute_off.sh` ma fallback usuwania plików z markerem nawet jeśli `/tmp` zniknęło po restarcie.

## Co jeśli odłączę hotspot w trybie ON?
W tej wersji host‑route’y są statyczne: jeśli hotspot zniknie, a routy nadal wskazują jego bramę, to połączenia do IP tej usługi mogą przestać działać.
Rozwiązanie: `./bin/splitroute off openai` (albo podłącz hotspot ponownie i zrób `refresh`).

## Czy to działa z Codex CLI i przeglądarką?
Tak — docelowo.
Jeśli widzisz problemy tylko przy wpiętym Ethernecie, najczęstszą przyczyną jest DNS blokowany po Ethernecie, a nie routing.
Patrz: `docs/case-study-openai.md`.
