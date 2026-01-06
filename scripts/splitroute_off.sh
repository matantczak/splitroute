#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SERVICE="${SERVICE:-openai}"
if [[ ! "$SERVICE" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "Nieprawidłowa nazwa SERVICE=$SERVICE (dozwolone: A-Z a-z 0-9 . _ -)" >&2
  exit 2
fi

WIFI_IF="${WIFI_IF:-en0}"
STATE_FILE="${STATE_FILE:-/tmp/splitroute_${SERVICE}_routes.txt}"
RESOLVER_STATE_FILE="${RESOLVER_STATE_FILE:-/tmp/splitroute_${SERVICE}_resolvers.txt}"
RESOLVER_DIR="${RESOLVER_DIR:-/etc/resolver}"
RESOLVER_MARKER="${RESOLVER_MARKER:-splitroute_managed:${SERVICE}}"
DNS_FLUSH="${DNS_FLUSH:-1}"

if [[ $EUID -ne 0 ]]; then
  echo "Uruchom tak: sudo $0"
  exit 1
fi

flush_dns_cache() {
  [[ "$DNS_FLUSH" == "1" ]] || return 0
  dscacheutil -flushcache >/dev/null 2>&1 || true
  killall -HUP mDNSResponder >/dev/null 2>&1 || true
}

did_routes=0
did_dns=0

if [[ -f "$STATE_FILE" ]]; then
  while read -r fam ip; do
    [[ -z "${ip:-}" ]] && continue
    if [[ "$fam" == "v6" ]]; then
      route -n delete -inet6 -host -ifscope "$WIFI_IF" "$ip" >/dev/null 2>&1 || true
      route -n delete -inet6 -host "$ip" >/dev/null 2>&1 || true
    else
      route -n delete -inet  -host -ifscope "$WIFI_IF" "$ip" >/dev/null 2>&1 || true
      route -n delete -inet  -host "$ip" >/dev/null 2>&1 || true
    fi
  done < "$STATE_FILE"
  rm -f "$STATE_FILE"
  did_routes=1
else
  echo "Brak $STATE_FILE — nie mam czego sprzątać w routingu. (Możliwe, że już jest czysto.)"
fi

if [[ -f "$RESOLVER_STATE_FILE" ]]; then
  while read -r resolver_file; do
    [[ -z "${resolver_file:-}" ]] && continue
    if [[ -f "$resolver_file" ]] && grep -q "$RESOLVER_MARKER" "$resolver_file" 2>/dev/null; then
      rm -f "$resolver_file" || true
      did_dns=1
    fi
  done < "$RESOLVER_STATE_FILE"
  rm -f "$RESOLVER_STATE_FILE"
elif [[ -d "$RESOLVER_DIR" ]]; then
  # Fallback (np. po restarcie, gdy /tmp zniknęło): usuń wszystkie pliki z markerem.
  for resolver_file in "$RESOLVER_DIR"/*; do
    [[ -f "$resolver_file" ]] || continue
    if grep -q "$RESOLVER_MARKER" "$resolver_file" 2>/dev/null; then
      rm -f "$resolver_file" || true
      did_dns=1
    fi
  done
fi

if [[ "$did_dns" -eq 1 ]]; then
  flush_dns_cache
fi

if [[ "$did_routes" -eq 1 || "$did_dns" -eq 1 ]]; then
  echo "OK: sprzątnięte (powrót do normalnego routingu/DNS)."
else
  echo "OK: nic do sprzątania."
fi
