#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SERVICE="${SERVICE:-openai}"
if [[ ! "$SERVICE" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "Nieprawidłowa nazwa SERVICE=$SERVICE (dozwolone: A-Z a-z 0-9 . _ -)" >&2
  exit 2
fi

WIFI_IF="${WIFI_IF:-en0}" # hotspot (Wi-Fi)

SERVICE_DIR="${SERVICE_DIR:-$PROJECT_ROOT/services/$SERVICE}"
HOSTS_FILE="${HOSTS_FILE:-$SERVICE_DIR/hosts.txt}"
DNS_DOMAINS_FILE="${DNS_DOMAINS_FILE:-$SERVICE_DIR/dns_domains.txt}"

STATE_FILE="${STATE_FILE:-/tmp/splitroute_${SERVICE}_routes.txt}"
RESOLVER_STATE_FILE="${RESOLVER_STATE_FILE:-/tmp/splitroute_${SERVICE}_resolvers.txt}"
RESOLVER_DIR="${RESOLVER_DIR:-/etc/resolver}"
RESOLVER_MARKER="${RESOLVER_MARKER:-splitroute_managed:${SERVICE}}"

VERBOSE="${VERBOSE:-0}"
DNS_OVERRIDE_DEFAULT="${DNS_OVERRIDE_DEFAULT:-}"
if [[ -z "${DNS_OVERRIDE_DEFAULT:-}" ]]; then
  DNS_OVERRIDE_DEFAULT="on"
fi
DNS_OVERRIDE="${DNS_OVERRIDE:-$DNS_OVERRIDE_DEFAULT}" # auto|on|off
DNS_SERVERS="${DNS_SERVERS:-1.1.1.1 1.0.0.1}"
DNS_DOMAINS="${DNS_DOMAINS:-}"
DNS_FLUSH="${DNS_FLUSH:-1}"

if [[ $EUID -ne 0 ]]; then
  echo "Uruchom tak: sudo $0"
  exit 1
fi

if [[ ! -f "$HOSTS_FILE" ]]; then
  echo "Brak pliku hostów: $HOSTS_FILE" >&2
  echo "Sprawdź: SERVICE=$SERVICE (szukam w $SERVICE_DIR)" >&2
  exit 1
fi

if [[ -z "${DNS_DOMAINS:-}" ]]; then
  if [[ -f "$DNS_DOMAINS_FILE" ]]; then
    DNS_DOMAINS="$(awk 'NF && $1 !~ /^#/{print $1}' "$DNS_DOMAINS_FILE" | tr '\n' ' ')"
  else
    DNS_DOMAINS="chatgpt.com openai.com openai.org oaistatic.com oaiusercontent.com"
  fi
fi

# Jeśli wcześniej włączono split-routing, wyczyść stare reguły przed ponownym dodaniem.
# (W przeciwnym razie stare IP mogłyby zostać w tablicy routingu na stałe.)
if [[ -f "$STATE_FILE" || -f "$RESOLVER_STATE_FILE" ]]; then
  if [[ -x "$SCRIPT_DIR/splitroute_off.sh" ]]; then
    echo "Wykryto poprzedni stan (SERVICE=$SERVICE) — czyszczę stare reguły..."
    SERVICE="$SERVICE" WIFI_IF="$WIFI_IF" \
      STATE_FILE="$STATE_FILE" RESOLVER_STATE_FILE="$RESOLVER_STATE_FILE" \
      RESOLVER_DIR="$RESOLVER_DIR" RESOLVER_MARKER="$RESOLVER_MARKER" DNS_FLUSH="$DNS_FLUSH" \
      "$SCRIPT_DIR/splitroute_off.sh" >/dev/null 2>&1 || true
  fi
fi

# IPv4 gateway hotspota
GW4="$(ipconfig getoption "$WIFI_IF" router 2>/dev/null || true)"
if [[ -z "${GW4:-}" ]]; then
  echo "Nie wykryłem bramy IPv4 dla $WIFI_IF. Czy Wi-Fi jest połączone z hotspotem iPhone?"
  exit 1
fi

# IPv6 gateway hotspota (może nie istnieć)
GW6="$(netstat -rn -f inet6 2>/dev/null | awk -v ifname="$WIFI_IF" '$1=="default" && $NF==ifname {print $2; exit}' || true)"
if [[ -z "${GW6:-}" ]]; then
  GW6="$(route -n get -inet6 default -ifscope "$WIFI_IF" 2>/dev/null | awk '/gateway:/{print $2; exit}' || true)"
fi
if [[ -n "${GW6:-}" && "$GW6" == fe80::* && "$GW6" != *%* ]]; then
  GW6="${GW6}%${WIFI_IF}"
fi
if [[ -n "${GW6:-}" && "$GW6" == *%* && "$GW6" != *"%$WIFI_IF" ]]; then
  # Nie używaj bramy z innego scoped interfejsu (np. utunX/en7)
  GW6=""
fi

: > "$STATE_FILE"
echo "Hotspot IF: $WIFI_IF"
echo "Service: $SERVICE"
echo "GW4: $GW4"
echo "GW6: ${GW6:-<brak>}"

flush_dns_cache() {
  [[ "$DNS_FLUSH" == "1" ]] || return 0
  dscacheutil -flushcache >/dev/null 2>&1 || true
  killall -HUP mDNSResponder >/dev/null 2>&1 || true
}

dns_looks_blocked() {
  local host="$1"
  local ips
  ips="$(
    {
      dscacheutil -q host -a name "$host" 2>/dev/null | awk '/ip_address:/{print $2}'
      dig +short A "$host" 2>/dev/null || true
    } | tr -d '\r' | grep -E '^[0-9.]+$' | sort -u
  )"
  [[ -z "$ips" ]] && return 1
  echo "$ips" | grep -qE '^146\.112\.61\.'
}

setup_dns_override() {
  mkdir -p "$RESOLVER_DIR"
  : > "$RESOLVER_STATE_FILE"

  local domain resolver_file tmp_file
  for domain in $DNS_DOMAINS; do
    resolver_file="$RESOLVER_DIR/$domain"

    if [[ -f "$resolver_file" ]] && ! grep -q "$RESOLVER_MARKER" "$resolver_file" 2>/dev/null; then
      echo "Uwaga: $resolver_file już istnieje i nie jest zarządzany przez ten skrypt — pomijam." >&2
      continue
    fi

    tmp_file="$(mktemp)"
    {
      echo "# $RESOLVER_MARKER"
      echo "# created_by: $0"
      echo "# created_at_utc: $(date -u +%FT%TZ)"
      echo "# primary: hotspot gateway (if it speaks DNS), then public fallback"
      echo "nameserver $GW4"
      for ns in $DNS_SERVERS; do
        echo "nameserver $ns"
      done
      echo "options timeout:1 attempts:1"
    } > "$tmp_file"

    mv "$tmp_file" "$resolver_file"
    chmod 644 "$resolver_file" || true
    echo "$resolver_file" >> "$RESOLVER_STATE_FILE"
  done

  sort -u -o "$RESOLVER_STATE_FILE" "$RESOLVER_STATE_FILE" >/dev/null 2>&1 || true
  flush_dns_cache
}

DNS_OVERRIDE_ENABLED=0
case "$DNS_OVERRIDE" in
  on)
    DNS_OVERRIDE_ENABLED=1
    ;;
  off)
    DNS_OVERRIDE_ENABLED=0
    ;;
  auto)
    # Heurystyka: wykryj typowy „blocked page” (np. Umbrella/OpenDNS) dla kilku pierwszych hostów usługi.
    PROBE_HOSTS="$(awk 'NF && $1 !~ /^#/{print $1}' "$HOSTS_FILE" | head -n 3 | tr '\n' ' ')"
    for h in $PROBE_HOSTS; do
      if dns_looks_blocked "$h"; then
        DNS_OVERRIDE_ENABLED=1
        break
      fi
    done
    ;;
  *)
    echo "Nieznana wartość DNS_OVERRIDE=$DNS_OVERRIDE (użyj: auto|on|off)" >&2
    exit 2
    ;;
esac

if [[ "$DNS_OVERRIDE_ENABLED" -eq 1 ]]; then
  echo "DNS override: ON (per-domain resolvers w $RESOLVER_DIR, usuń przez splitroute_off.sh)"
  setup_dns_override
fi

add_v4() {
  local ip="$1"
  # Usuń ewentualne wcześniejsze wpisy (np. z poprzednich prób) i dodaj trasę nieskopowaną,
  # żeby działała dla zwykłych socketów (browser/Codex) mimo aktywnego Ethernetu.
  route -n delete -inet -host -ifscope "$WIFI_IF" "$ip" >/dev/null 2>&1 || true
  route -n delete -inet -host "$ip" >/dev/null 2>&1 || true
  if [[ "$VERBOSE" == "1" ]]; then
    route -n add -inet -host "$ip" "$GW4" || true
  else
    route -n add -inet -host "$ip" "$GW4" >/dev/null 2>&1 || true
  fi
  echo "v4 $ip" >> "$STATE_FILE"
}

add_v6() {
  local ip6="$1"
  [[ -z "${GW6:-}" ]] && return 0
  if [[ "$VERBOSE" == "1" ]]; then
    route -n add -inet6 -host -ifscope "$WIFI_IF" "$ip6" "$GW6" || true
  else
    route -n add -inet6 -host -ifscope "$WIFI_IF" "$ip6" "$GW6" >/dev/null 2>&1 || true
  fi
  echo "v6 $ip6" >> "$STATE_FILE"
}

resolve_v4() {
  local host="$1"
  {
    dscacheutil -q host -a name "$host" 2>/dev/null | awk '/ip_address:/{print $2}' | grep -E '^[0-9.]+$' || true
    if [[ "$DNS_OVERRIDE_ENABLED" -eq 0 ]]; then
      dig +short A "$host" 2>/dev/null | grep -E '^[0-9.]+$' || true
    fi
  } | sort -u
}

resolve_v6() {
  local host="$1"
  {
    dscacheutil -q host -a name "$host" 2>/dev/null | awk '/ipv6_address:/{print $2}' | grep -E ':' || true
    if [[ "$DNS_OVERRIDE_ENABLED" -eq 0 ]]; then
      dig +short AAAA "$host" 2>/dev/null | grep -E ':' || true
    fi
  } | sort -u
}

TMP_IPS="$(mktemp)"
cleanup() { rm -f "$TMP_IPS"; }
trap cleanup EXIT

while read -r host; do
  [[ -z "$host" ]] && continue
  [[ "$host" =~ ^# ]] && continue

  # IPv4
  resolve_v4 "$host" | awk '{print "v4\t"$0}' >> "$TMP_IPS"

  # IPv6
  resolve_v6 "$host" | awk '{print "v6\t"$0}' >> "$TMP_IPS"

done < "$HOSTS_FILE"

sort -u "$TMP_IPS" | while IFS=$'\t' read -r fam ip; do
  [[ -z "${ip:-}" ]] && continue
  if [[ "$fam" == "v6" ]]; then
    add_v6 "$ip"
  else
    add_v4 "$ip"
  fi
done

sort -u -o "$STATE_FILE" "$STATE_FILE" >/dev/null 2>&1 || true
echo "OK: dodane trasy zapisane w $STATE_FILE"
