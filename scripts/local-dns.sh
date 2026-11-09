#!/usr/bin/env bash
# macOS + Linux: make THIS machine resolve the failover name (e.g. app.univen-dr-demo.com)
# straight from the hosted zone's Route 53 name servers, so a browser can open
# http://<failover_fqdn> and follow the live failover, without owning the domain.
# (Windows: use scripts/local-dns.ps1)
#
#   macOS  -> /etc/resolver/<fqdn>
#   Linux  -> systemd-resolved drop-in /etc/systemd/resolved.conf.d/univen-local-dns.conf
#             (Ubuntu, Fedora, Debian 12+, Pop!_OS, Mint 21+ ... use systemd-resolved)
#
# Only that one name is routed to Route 53; other lookups keep working as before.
# Needs sudo for on/off.
#
# Usage: scripts/local-dns.sh on       # after every deploy (name servers change)
#        scripts/local-dns.sh status   # show what the system resolves now
#        scripts/local-dns.sh off      # remove the override when you're done
#        scripts/local-dns.sh on --dry-run
#
# Overrides (mainly for testing without a deployed stack):
#   LOCAL_DNS_FQDN="name.example.com"  LOCAL_DNS_NAMESERVERS="192.0.2.1 192.0.2.2"
set -euo pipefail

TF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="${1:-status}"
DRY_RUN="${2:-}"
OS="$(uname -s)"
MARKER="# Added by univen-cloud scripts/local-dns.sh. Remove with: scripts/local-dns.sh off"
LINUX_DROPIN="/etc/systemd/resolved.conf.d/univen-local-dns.conf"

die() { echo "ERROR: $*" >&2; exit 1; }

case "$OS" in
  Darwin|Linux) ;;
  *) die "Unsupported OS '$OS'. On Windows use scripts/local-dns.ps1" ;;
esac

tf() { command -v terraform >/dev/null || die "terraform not found"; terraform -chdir="$TF_DIR" "$@"; }

FQDN="${LOCAL_DNS_FQDN:-$(tf output -raw failover_fqdn)}"
[[ -n "$FQDN" ]] || die "could not read failover_fqdn (run after terraform apply)"

# Resolve a hostname to its first IPv4 address (dig if present, else getent).
resolve_v4() {
  if command -v dig >/dev/null; then
    dig +short "$1" A | grep -E '^[0-9]+(\.[0-9]+){3}$' | head -1 || true
  else
    getent ahostsv4 "$1" | awk 'NR==1 {print $1}' || true
  fi
}

# Route 53 name server IPs (resolver configs need IPs, not hostnames).
nameserver_ips() {
  if [[ -n "${LOCAL_DNS_NAMESERVERS:-}" ]]; then tr ' ' '\n' <<<"$LOCAL_DNS_NAMESERVERS"; return; fi
  command -v jq >/dev/null || die "jq not found"
  local ns ip
  for ns in $(tf output -json route53_name_servers | jq -r '.[]'); do
    ip=$(resolve_v4 "$ns"); [[ -n "$ip" ]] && echo "$ip"
  done
}

# What the OS resolver (the one browsers use) returns for the name right now.
system_lookup() {
  if [[ "$OS" == Darwin ]]; then
    dscacheutil -q host -a name "$FQDN" | awk '/ip_address/ {print $2}' | tr '\n' ' '
  else
    getent ahostsv4 "$FQDN" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' '
  fi
}

flush() {
  if [[ "$OS" == Darwin ]]; then
    sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder 2>/dev/null || true
  else
    sudo resolvectl flush-caches 2>/dev/null || true
  fi
}

# Linux: only systemd-resolved is supported; make sure apps actually use it.
linux_preflight() {
  command -v resolvectl >/dev/null || die "systemd-resolved (resolvectl) not found. This Linux
       distro needs a manual setup: route '$FQDN' to the Route 53 name servers in your DNS
       forwarder (e.g. dnsmasq: server=/$FQDN/<ns-ip>)."
  systemctl is-active --quiet systemd-resolved || die "systemd-resolved is installed but not running"
  if ! grep -Eq '^nameserver[[:space:]]+127\.0\.0\.53' /etc/resolv.conf 2>/dev/null \
     && ! grep -q 'resolve' /etc/nsswitch.conf 2>/dev/null; then
    die "/etc/resolv.conf doesn't point at systemd-resolved (127.0.0.53), so apps would
       bypass it. Fix: sudo ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf"
  fi
}

config_path() { [[ "$OS" == Darwin ]] && echo "/etc/resolver/$FQDN" || echo "$LINUX_DROPIN"; }

render_config() { # $@ = name server IPs
  if [[ "$OS" == Darwin ]]; then
    printf '%s\n' "$MARKER"
    printf 'nameserver %s\n' "$@"
    printf 'timeout 3\n'
  else
    # Global DNS servers + a routing-only domain (~name): lookups for $FQDN go to
    # Route 53. Other lookups still get answered by your normal per-link DNS;
    # systemd-resolved uses the first successful answer, and Route 53 just
    # refuses names it isn't authoritative for.
    printf '%s\n[Resolve]\nDNS=%s\nDomains=~%s\n' "$MARKER" "$*" "$FQDN"
  fi
}

status() {
  local cfg; cfg=$(config_path)
  echo "Failover name: $FQDN"
  if [[ -f "$cfg" ]] && grep -qF "$MARKER" "$cfg"; then
    echo "Override:      ON ($cfg)"; grep -v '^#' "$cfg" | sed 's/^/                 /'
  else echo "Override:      OFF"; fi
  local ips; ips=$(system_lookup)
  echo "System lookup: ${ips:-<no answer>}"
}

case "$ACTION" in
  on)
    [[ "$OS" == Linux && "$DRY_RUN" != "--dry-run" ]] && linux_preflight
    mapfile_ips=()
    while IFS= read -r ip; do [[ -n "$ip" ]] && mapfile_ips+=("$ip"); done < <(nameserver_ips)
    [[ ${#mapfile_ips[@]} -gt 0 ]] || die "could not resolve the Route 53 name servers"
    CFG=$(config_path); CONTENT=$(render_config "${mapfile_ips[@]}")

    if [[ "$DRY_RUN" == "--dry-run" ]]; then
      echo "Would write $CFG:"; echo "$CONTENT"; exit 0
    fi
    sudo mkdir -p "$(dirname "$CFG")"
    echo "$CONTENT" | sudo tee "$CFG" >/dev/null
    [[ "$OS" == Linux ]] && sudo systemctl restart systemd-resolved
    flush
    echo "Done. Open http://$FQDN in your browser."
    echo "Tip: if the browser doesn't follow a failover, clear its DNS cache"
    echo "     (Chrome/Edge: chrome://net-internals/#dns -> Clear host cache) or open a new private window."
    echo
    status
    ;;
  off)
    CFG=$(config_path)
    if [[ -f "$CFG" ]] && grep -qF "$MARKER" "$CFG"; then
      sudo rm -f "$CFG"
      [[ "$OS" == Linux ]] && sudo systemctl restart systemd-resolved
      flush; echo "Removed $CFG"
    else echo "Nothing to remove ($CFG not present or not ours)"; fi
    ;;
  status) status ;;
  *) echo "Usage: $0 on|off|status [--dry-run]" >&2; exit 2 ;;
esac
