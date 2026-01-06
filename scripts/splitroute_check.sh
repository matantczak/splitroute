#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SERVICE="${SERVICE:-openai}"
if [[ ! "$SERVICE" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "Nieprawidłowa nazwa SERVICE=$SERVICE (dozwolone: A-Z a-z 0-9 . _ -)" >&2
  exit 2
fi

SERVICE_DIR="${SERVICE_DIR:-$PROJECT_ROOT/services/$SERVICE}"

WIFI_IF="${WIFI_IF:-en0}"
ETH_IF="${ETH_IF:-en7}"
HOSTS_FILE="${HOSTS_FILE:-$SERVICE_DIR/hosts.txt}"
STATE_FILE="${STATE_FILE:-/tmp/splitroute_${SERVICE}_routes.txt}"

DO_CURL=1
CURL_ALL=0
FILTER_HOST=""
PID=""
CONTROL=0
CONTROL_HOST="${CONTROL_HOST:-example.com}"
DEFAULT_PROBE_IP="${DEFAULT_PROBE_IP:-1.1.1.1}"

CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-5}"
MAX_TIME="${MAX_TIME:-12}"

usage() {
  cat <<EOF
Usage: sudo $0 [--no-curl] [--curl-all] [--host <hostname>]
          sudo $0 --pid <PID> [--no-curl]
          sudo $0 --control [--control-host <hostname>] [--no-curl]

Checks:
  - default routes (IPv4/IPv6)
  - resolved A/AAAA for hosts from $HOSTS_FILE
  - which interface macOS will use (route get)
  - (optional) live established connections for a given PID (lsof)
  - optional HTTPS probes via curl (no headers/tokens printed)
  - (optional) control test: control host should follow default IPv4 route

Env overrides:
  SERVICE=openai WIFI_IF=en0 ETH_IF=en7 SERVICE_DIR=... HOSTS_FILE=... STATE_FILE=...
  CONTROL_HOST=example.com DEFAULT_PROBE_IP=1.1.1.1
  CONNECT_TIMEOUT=5 MAX_TIME=12
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-curl)
      DO_CURL=0
      shift
      ;;
    --curl-all)
      CURL_ALL=1
      shift
      ;;
    --host)
      FILTER_HOST="${2:-}"
      shift 2
      ;;
    --pid)
      PID="${2:-}"
      shift 2
      ;;
    --control)
      CONTROL=1
      shift
      ;;
    --control-host)
      CONTROL_HOST="${2:-}"
      CONTROL=1
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "Run with sudo (needs 'route get'). Example: sudo $0" >&2
  exit 1
fi

if [[ ! -f "$HOSTS_FILE" ]]; then
  echo "Missing hosts file: $HOSTS_FILE" >&2
  exit 1
fi

if [[ -n "$PID" && ! "$PID" =~ ^[0-9]+$ ]]; then
  echo "--pid must be a number (got: $PID)" >&2
  exit 2
fi

if [[ "$CONTROL" -eq 1 && -z "$CONTROL_HOST" ]]; then
  echo "--control-host requires a hostname" >&2
  exit 2
fi

have_cmd() { command -v "$1" >/dev/null 2>&1; }

normalize_ip() {
  # macOS potrafi zwrócić IPv4-mapped IPv6 (np. ::ffff:1.2.3.4) — traktujemy to jak IPv4.
  local ip="$1"
  if [[ "$ip" =~ ^::ffff:([0-9.]+)$ ]]; then
    printf "%s" "${BASH_REMATCH[1]}"
    return 0
  fi
  printf "%s" "$ip"
}

iface_status() {
  local ifname="$1"
  if ! ifconfig "$ifname" >/dev/null 2>&1; then
    echo "missing"
    return 0
  fi
  local st
  st="$(ifconfig "$ifname" 2>/dev/null | awk -F': ' '/status:/{print $2; exit}')"
  echo "${st:-unknown}"
}

resolve_ips() {
  local host="$1"
  local ips
  ips="$(
    dscacheutil -q host -a name "$host" 2>/dev/null \
      | awk '/^(ip_address|ipv6_address):/{print $2}' \
      | tr -d '\r' \
      | awk 'NF' \
      || true
  )"
  if [[ -z "$ips" ]] && have_cmd dig; then
    ips="$(
      {
        dig +short A "$host" 2>/dev/null || true
        dig +short AAAA "$host" 2>/dev/null || true
      } | tr -d '\r' | awk 'NF'
    )"
  fi
  printf "%s\n" "$ips" | while read -r ip; do normalize_ip "$ip"; echo; done | awk 'NF' | sort -u
}

route_iface_for_ip() {
  local ip="$1"
  local out iface gw
  if [[ "$ip" == *:* ]]; then
    out="$(route -n get -inet6 "$ip" 2>/dev/null || true)"
  else
    out="$(route -n get "$ip" 2>/dev/null || true)"
  fi
  iface="$(printf "%s\n" "$out" | awk '/interface:/{print $2; exit}')"
  gw="$(printf "%s\n" "$out" | awk '/gateway:/{print $2; exit}')"
  printf "%s\t%s" "${iface:-?}" "${gw:-?}"
}

curl_probe() {
  local label="$1"
  local iface="$2"  # "" for auto
  local host="$3"
  local url="$4"

  local tmp_err out rc remote_ip http_code ssl_verify time_total route_if
  tmp_err="$(mktemp)"
  if [[ -n "$iface" ]]; then
    out="$(curl -sS --interface "$iface" --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" -o /dev/null \
      -w "%{remote_ip} %{http_code} %{ssl_verify_result} %{time_total}\n" "$url" 2>"$tmp_err" || true)"
    rc=0
  else
    out="$(curl -sS --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" -o /dev/null \
      -w "%{remote_ip} %{http_code} %{ssl_verify_result} %{time_total}\n" "$url" 2>"$tmp_err" || true)"
    rc=0
  fi

  if [[ -s "$tmp_err" ]]; then
    local err
    err="$(tr '\n' ' ' <"$tmp_err" | sed -E 's/[[:space:]]+/ /g' | head -c 240)"
    rm -f "$tmp_err"
    printf "CURL\t%s\t%s\tERR\t%s\n" "$label" "$host" "$err"
    return 0
  fi
  rm -f "$tmp_err"

  remote_ip="$(printf "%s\n" "$out" | awk '{print $1}')"
  http_code="$(printf "%s\n" "$out" | awk '{print $2}')"
  ssl_verify="$(printf "%s\n" "$out" | awk '{print $3}')"
  time_total="$(printf "%s\n" "$out" | awk '{print $4}')"

  route_if="?"
  if [[ -n "${remote_ip:-}" ]]; then
    route_if="$(route_iface_for_ip "$remote_ip" | awk -F'\t' '{print $1}')"
  fi

  printf "CURL\t%s\t%s\tip=%s\troute_if=%s\thttp=%s\ttls_verify=%s\tt=%ss\n" \
    "$label" "$host" "${remote_ip:-?}" "${route_if:-?}" "${http_code:-?}" "${ssl_verify:-?}" "${time_total:-?}"
}

echo "== Interfaces =="
echo "SERVICE=$SERVICE (hosts: $HOSTS_FILE)"
echo "WIFI_IF=$WIFI_IF (status: $(iface_status "$WIFI_IF"))"
echo "ETH_IF=$ETH_IF (status: $(iface_status "$ETH_IF"))"
echo

echo "== Default routes =="
echo "-- IPv4"
netstat -rn -f inet 2>/dev/null | awk 'NR<=6{print}'
echo "-- IPv6 (all defaults)"
netstat -rn -f inet6 2>/dev/null | awk '$1=="default"{print}'
echo

WIFI_V6_DEFAULT_GW="$(netstat -rn -f inet6 2>/dev/null | awk -v ifname="$WIFI_IF" '$1=="default" && $NF==ifname {print $2; exit}' || true)"
WIFI_HAS_V6_DEFAULT=0
if [[ -n "${WIFI_V6_DEFAULT_GW:-}" ]]; then
  WIFI_HAS_V6_DEFAULT=1
fi

echo "== Tools =="
echo "curl: $(command -v curl 2>/dev/null || echo '<missing>')"
curl -V 2>/dev/null | head -n 2 || true
echo "dig:  $(command -v dig 2>/dev/null || echo '<missing>')"
echo

GW4_WIFI="$(ipconfig getoption "$WIFI_IF" router 2>/dev/null || true)"
HOTSPOT_UP=0
if [[ -n "${GW4_WIFI:-}" ]]; then
  HOTSPOT_UP=1
fi
echo "== Hotspot =="
echo "GW4($WIFI_IF)=${GW4_WIFI:-<brak>}"
echo

echo "== Route table check (expected SERVICE=$SERVICE via $WIFI_IF when hotspot up) =="
echo -e "host\tfam\tip\troute_if\tgateway\tstatus"

DNS_BLOCK=0
while read -r host; do
  [[ -z "$host" ]] && continue
  [[ "$host" =~ ^# ]] && continue
  [[ -n "$FILTER_HOST" && "$host" != "$FILTER_HOST" ]] && continue

  ips="$(resolve_ips "$host" || true)"
  if [[ -z "$ips" ]]; then
    echo -e "${host}\t-\t-\t-\t-\tNO_DNS"
    continue
  fi

  while read -r ip; do
    [[ -z "$ip" ]] && continue
    fam="v4"
    [[ "$ip" == *:* ]] && fam="v6"
    if [[ "$fam" == "v4" && "$ip" =~ ^146\\.112\\.61\\.[0-9]+$ ]]; then
      DNS_BLOCK=1
    fi
    route_info="$(route_iface_for_ip "$ip")"
    route_if="$(printf "%s" "$route_info" | awk -F'\t' '{print $1}')"
    gw="$(printf "%s" "$route_info" | awk -F'\t' '{print $2}')"

    status="OK"
    if [[ "$HOTSPOT_UP" -eq 1 ]]; then
      if [[ "$route_if" != "$WIFI_IF" ]]; then
        if [[ "$fam" == "v6" && "$WIFI_HAS_V6_DEFAULT" -eq 0 ]]; then
          status="NO_V6_ON_$WIFI_IF"
        else
          status="NOT_$WIFI_IF"
        fi
      fi
    else
      status="HOTSPOT_DOWN"
    fi
    echo -e "${host}\t${fam}\t${ip}\t${route_if}\t${gw}\t${status}"
  done <<<"$ips"
done < "$HOSTS_FILE"

if [[ "$DNS_BLOCK" -eq 1 ]]; then
  echo
  echo "!! Warning: wykryto IP 146.112.61.x (często Cisco Umbrella/OpenDNS 'blocked page')."
  echo "   Jeśli to dotyczy chatgpt.com/openai.com, to problemem jest DNS (nie routing)."
  echo "   Szybki test: dig +short @1.1.1.1 chatgpt.com (powinno zwrócić inne IP niż 146.112.61.x)"
fi

if [[ "$CONTROL" -eq 1 ]]; then
  echo
  echo "== Control test (control host should follow default IPv4 route) =="
  default_info="$(route_iface_for_ip "$DEFAULT_PROBE_IP")"
  default_if="$(printf "%s" "$default_info" | awk -F'\t' '{print $1}')"
  default_gw="$(printf "%s" "$default_info" | awk -F'\t' '{print $2}')"
  echo "default_probe_ip=$DEFAULT_PROBE_IP route_if=${default_if:-?} gateway=${default_gw:-?}"
  echo -e "host\tip\troute_if\tgateway\tstatus"

  control_ips="$(resolve_ips "$CONTROL_HOST" | awk '$0 !~ /:/' || true)"
  if [[ -z "$control_ips" ]]; then
    echo -e "${CONTROL_HOST}\t-\t-\t-\tNO_DNS"
  else
    while read -r ip; do
      [[ -z "$ip" ]] && continue
      route_info="$(route_iface_for_ip "$ip")"
      route_if="$(printf "%s" "$route_info" | awk -F'\t' '{print $1}')"
      gw="$(printf "%s" "$route_info" | awk -F'\t' '{print $2}')"

      status="OK"
      if [[ -n "${default_if:-}" && "$route_if" != "$default_if" ]]; then
        status="NOT_DEFAULT"
      fi
      if [[ "$HOTSPOT_UP" -eq 1 && "$route_if" == "$WIFI_IF" && "$default_if" != "$WIFI_IF" ]]; then
        status="UNEXPECTED_$WIFI_IF"
      fi

      echo -e "${CONTROL_HOST}\t${ip}\t${route_if}\t${gw}\t${status}"
    done <<<"$control_ips"
  fi
fi

if [[ -n "$PID" ]]; then
  echo
  echo "== Live connections (PID=$PID) =="
  if ! have_cmd lsof; then
    echo "Missing 'lsof' in PATH."
  else
    if ! kill -0 "$PID" 2>/dev/null; then
      echo "PID not running: $PID"
    else
      echo -e "remote_ip\tremote_port\troute_if\tgateway"
      lsof -nP -p "$PID" -iTCP -sTCP:ESTABLISHED 2>/dev/null \
        | awk 'NR>1{print $0}' \
        | while IFS= read -r line; do
            remote="$(printf "%s\n" "$line" | sed -E 's/.*->([^ ]+).*/\\1/' || true)"
            [[ -z "${remote:-}" ]] && continue

            rip=""
            rport=""
            if [[ "$remote" =~ ^\\[([^\\]]+)\\]:([0-9]+)$ ]]; then
              rip="${BASH_REMATCH[1]}"
              rport="${BASH_REMATCH[2]}"
            else
              rip="${remote%:*}"
              rport="${remote##*:}"
            fi

            [[ -z "${rip:-}" ]] && continue
            route_info="$(route_iface_for_ip "$rip")"
            route_if="$(printf "%s" "$route_info" | awk -F'\t' '{print $1}')"
            gw="$(printf "%s" "$route_info" | awk -F'\t' '{print $2}')"
            echo -e "${rip}\t${rport:-?}\t${route_if}\t${gw}"
          done
    fi
  fi
fi

if [[ "$DO_CURL" -eq 0 ]]; then
  exit 0
fi

echo
echo "== HTTPS probes (no headers) =="

hosts_to_probe="chatgpt.com api.openai.com auth.openai.com"
if [[ "$CURL_ALL" -eq 1 ]]; then
  hosts_to_probe="$(awk 'NF && $1 !~ /^#/{print $1}' "$HOSTS_FILE" | tr '\n' ' ')"
fi
if [[ -n "$FILTER_HOST" ]]; then
  hosts_to_probe="$FILTER_HOST"
fi

for h in $hosts_to_probe; do
  url="https://$h/"
  if [[ "$h" == "api.openai.com" ]]; then
    url="https://api.openai.com/v1/models"
  fi

  curl_probe "AUTO" "" "$h" "$url"
  if [[ "$(iface_status "$WIFI_IF")" == "active" ]]; then
    curl_probe "IF:$WIFI_IF" "$WIFI_IF" "$h" "$url"
  fi
  if [[ "$(iface_status "$ETH_IF")" == "active" ]]; then
    curl_probe "IF:$ETH_IF" "$ETH_IF" "$h" "$url"
  fi
done
