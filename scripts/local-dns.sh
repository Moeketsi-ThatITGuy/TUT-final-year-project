#!/usr/bin/env bash
# macOS: make THIS laptop resolve the failover name (e.g. app.univen-dr-demo.com)
# straight from the hosted zone's Route 53 name servers, so a browser can open
# http://<failover_fqdn> and follow the live failover, without owning the domain.
#
# Only that one name is affected; all other DNS is untouched.
# Needs sudo for on/off (writes /etc/resolver/<fqdn>).
#
# Usage: scripts/local-dns.sh on       # after every deploy (name servers change)
#        scripts/local-dns.sh status   # show what the system resolves now
#        scripts/local-dns.sh off      # remove the override when you're done
#        scripts/local-dns.sh on --dry-run
set -euo pipefail

TF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="${1:-status}"
DRY_RUN="${2:-}"

[[ "$(uname -s)" == "Darwin" ]] || { echo "This script is for macOS. On Windows use scripts/local-dns.ps1" >&2; exit 1; }
command -v terraform >/dev/null || { echo "ERROR: terraform not found" >&2; exit 1; }

FQDN=$(terraform -chdir="$TF_DIR" output -raw failover_fqdn)
RESOLVER_FILE="/etc/resolver/$FQDN"

flush() {
  sudo dscacheutil -flushcache
  sudo killall -HUP mDNSResponder 2>/dev/null || true
}

status() {
  echo "Failover name: $FQDN"
  if [[ -f "$RESOLVER_FILE" ]]; then echo "Override:      ON ($RESOLVER_FILE)"; sed 's/^/                 /' "$RESOLVER_FILE"
  else echo "Override:      OFF"; fi
  # dscacheutil uses the system resolver (honours /etc/resolver); dig does not.
  local ips; ips=$(dscacheutil -q host -a name "$FQDN" | awk '/ip_address/ {print $2}' | tr '\n' ' ')
  echo "System lookup: ${ips:-<no answer>}"
}

case "$ACTION" in
  on)
    command -v jq >/dev/null || { echo "ERROR: jq not found" >&2; exit 1; }
    # Route 53 name servers are hostnames; resolver(5) needs IPv4 addresses.
    NS_IPS=()
    for ns in $(terraform -chdir="$TF_DIR" output -json route53_name_servers | jq -r '.[]'); do
      ip=$(dig +short "$ns" A | grep -E '^[0-9.]+$' | head -1 || true)
      [[ -n "$ip" ]] && NS_IPS+=("$ip")
    done
    [[ ${#NS_IPS[@]} -gt 0 ]] || { echo "ERROR: could not resolve the Route 53 name servers" >&2; exit 1; }

    CONTENT="# Added by univen-cloud scripts/local-dns.sh. Remove with: scripts/local-dns.sh off"$'\n'
    for ip in "${NS_IPS[@]}"; do CONTENT+="nameserver $ip"$'\n'; done
    CONTENT+="timeout 3"$'\n'

    if [[ "$DRY_RUN" == "--dry-run" ]]; then
      echo "Would write $RESOLVER_FILE:"; printf '%s' "$CONTENT"; exit 0
    fi
    sudo mkdir -p /etc/resolver
    printf '%s' "$CONTENT" | sudo tee "$RESOLVER_FILE" >/dev/null
    flush
    echo "Done. Open http://$FQDN in your browser."
    echo "Tip: if the browser doesn't follow a failover, clear its DNS cache"
    echo "     (Chrome/Edge: chrome://net-internals/#dns -> Clear host cache) or open a new private window."
    echo
    status
    ;;
  off)
    if [[ -f "$RESOLVER_FILE" ]]; then sudo rm -f "$RESOLVER_FILE"; flush; echo "Removed $RESOLVER_FILE"
    else echo "Nothing to remove ($RESOLVER_FILE not present)"; fi
    ;;
  status) status ;;
  *) echo "Usage: $0 on|off|status [--dry-run]" >&2; exit 2 ;;
esac
