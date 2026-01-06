# Migracja z „home scripts” do repo `splitroute`

Ten dokument jest checklistą migracji z plików w katalogu domowym:
- `~/openai_on.sh`
- `~/openai_off.sh`
- `~/openai_check.sh`
- `~/openai_hosts.txt`

…na nowe repo `splitroute` (sklonowane/umieszczone gdziekolwiek).

## Dlaczego ta migracja wymaga ostrożności

W trakcie rozmowy wyszło, że w sieci po Ethernecie DNS mógł być podmieniany (np. Umbrella/OpenDNS → `146.112.61.x`).
W takim układzie **wyłączenie** starego trybu (`openai_off.sh`) może chwilowo „odciąć” OpenAI/ChatGPT/Codex, dopóki nie włączysz nowego trybu w `splitroute`.

Dlatego poniżej są dwie ścieżki:
- **A (zalecana):** migracja bez ryzyka utraty dostępu — na czas przełączenia odłącz Ethernet.
- **B:** szybka migracja bez odłączania — wymaga gotowych komend „kopiuj‑wklej”.

## Przed startem

1) Otwórz ten plik lokalnie (offline), żeby mieć instrukcję nawet bez dostępu do OpenAI:
`docs/migration.md`

2) Upewnij się, że projekt działa:
```bash
cd /path/to/splitroute
./bin/splitroute list
./bin/splitroute help
```

## A) Zalecane: migracja bez przerwy w dostępie (odłącz Ethernet na chwilę)

1) **Odłącz Ethernet** (wyjmij kabel/dock lub wyłącz interfejs), tak żeby jedynym łączem był hotspot (`en0`).
   - W tym momencie nawet bez split‑routingu OpenAI powinno działać normalnie przez hotspot.

2) Wyłącz stary tryb i posprzątaj:
```bash
sudo ~/openai_off.sh
```

3) Włącz nowy tryb (OpenAI) w repo:
```bash
cd /path/to/splitroute
./bin/splitroute on openai
```

4) (Opcjonalnie) Zweryfikuj na hotspocie:
```bash
./bin/splitroute check openai -- --host chatgpt.com --control --no-curl
```

5) **Podłącz Ethernet z powrotem** i sprawdź split‑routing:
```bash
cd /path/to/splitroute
./bin/splitroute check openai -- --host chatgpt.com --control
```
Jeśli zobaczysz IP `146.112.61.x` (Umbrella/OpenDNS) albo błąd certyfikatu w `curl`, wykonaj:
```bash
cd /path/to/splitroute && DNS_OVERRIDE=on ./bin/splitroute refresh openai
```
…i powtórz `check`.

## B) Alternatywnie: migracja „na żywo” bez odłączania Ethernetu (może być krótkie okno braku dostępu)

1) Skopiuj poniższe 2 komendy do schowka, żeby wkleić je od razu jedna po drugiej:

Wyłącz stare:
```bash
sudo ~/openai_off.sh
```

Włącz nowe:
```bash
cd /path/to/splitroute && ./bin/splitroute on openai
```

2) Po włączeniu — weryfikacja:
```bash
cd /path/to/splitroute && ./bin/splitroute check openai -- --host chatgpt.com --control
```

## Po migracji: czyszczenie i usuwanie starych plików

1) Upewnij się, że `off` działa z nowego projektu:
```bash
cd /path/to/splitroute && ./bin/splitroute off openai
```

2) Upewnij się, że nie ma już starych plików `/etc/resolver` (marker starego narzędzia):
```bash
sudo grep -R "openai_splitrouting_managed" /etc/resolver 2>/dev/null || true
```
Jeśli coś się pojawi, uruchom jeszcze raz:
```bash
sudo ~/openai_off.sh
```

3) Dopiero teraz usuń stare pliki z katalogu domowego (jeśli chcesz):
- `~/openai_on.sh`
- `~/openai_off.sh`
- `~/openai_check.sh`
- `~/openai_hosts.txt`

Rekomendacja praktyczna: zostaw je 1–2 dni jako „plan awaryjny”, a potem usuń.

## Jak odpalić nowy tryb, jeśli coś nagle przestanie działać

Najkrótsza ścieżka:
```bash
cd /path/to/splitroute && ./bin/splitroute refresh openai
```

Jeśli podejrzewasz DNS blokowany po Ethernecie (np. powrót `146.112.61.x`):
```bash
cd /path/to/splitroute && DNS_OVERRIDE=on ./bin/splitroute refresh openai
```
