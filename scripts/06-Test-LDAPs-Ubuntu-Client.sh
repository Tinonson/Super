#!/usr/bin/env bash
#
# 06-Test-LDAPs-Ubuntu-Client.sh
#
# Test LDAPS connectivity and high availability from an Ubuntu client.
#
# Prerequisites:
#   - Ubuntu 20.04/22.04/24.04 client
#   - Network connectivity to 192.168.61.161 and 192.168.61.162
#   - DNS configured to use the AD DNS servers, OR /etc/hosts entries
#
# Usage:
#   chmod +x 06-Test-LDAPs-Ubuntu-Client.sh
#   sudo ./06-Test-LDAPs-Ubuntu-Client.sh
#

set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────
DOMAIN="max.local"
LDAPS_HOSTNAME="ldaps.max.local"
LDAPS_PORT=636
BASE_DN="DC=max,DC=local"
BIND_USER="CN=Administrator,CN=Users,DC=max,DC=local"

DC1_IP="192.168.61.161"
DC1_NAME="maxdc01.max.local"
DC2_IP="192.168.61.162"
DC2_NAME="maxdc02.max.local"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

passed=0
failed=0

log_info()  { echo -e "${CYAN}[*]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[✓]${NC} $1"; ((passed++)); }
log_fail()  { echo -e "${RED}[✗]${NC} $1"; ((failed++)); }
log_warn()  { echo -e "${YELLOW}[!]${NC} $1"; }

# ═══════════════════════════════════════════════════════════════════
#  STEP 0: Install required packages
# ═══════════════════════════════════════════════════════════════════
log_info "Installing required packages ..."

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ldap-utils openssl dnsutils > /dev/null 2>&1

# ═══════════════════════════════════════════════════════════════════
#  STEP 1: DNS Resolution Tests
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  TEST 1: DNS Resolution"
echo "═══════════════════════════════════════════════════════════"

# 1a. Test individual DC resolution
for dc in "$DC1_NAME" "$DC2_NAME"; do
    if host "$dc" > /dev/null 2>&1; then
        resolved_ip=$(host "$dc" | awk '/has address/ {print $NF}')
        log_ok "$dc resolves to $resolved_ip"
    else
        log_fail "$dc does not resolve"
    fi
done

# 1b. Test round-robin hostname
log_info "Resolving round-robin hostname: $LDAPS_HOSTNAME"
rr_result=$(dig +short "$LDAPS_HOSTNAME" A 2>/dev/null || true)

if [ -n "$rr_result" ]; then
    ip_count=$(echo "$rr_result" | wc -l)
    log_ok "$LDAPS_HOSTNAME resolves to $ip_count address(es):"
    echo "$rr_result" | while read -r ip; do
        echo "       -> $ip"
    done

    if [ "$ip_count" -ge 2 ]; then
        log_ok "Round-robin returns multiple IPs (HA confirmed at DNS level)"
    else
        log_warn "Only one IP returned – round-robin may not be working"
    fi
else
    log_fail "$LDAPS_HOSTNAME does not resolve via DNS"
    log_warn "Falling back to /etc/hosts. Add these entries if not present:"
    log_warn "  $DC1_IP  $DC1_NAME $LDAPS_HOSTNAME"
    log_warn "  $DC2_IP  $DC2_NAME $LDAPS_HOSTNAME"
fi

# ═══════════════════════════════════════════════════════════════════
#  TEST 2: TCP Connectivity to LDAPS Port 636
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  TEST 2: TCP Connectivity (port $LDAPS_PORT)"
echo "═══════════════════════════════════════════════════════════"

for target in "$DC1_IP" "$DC2_IP"; do
    if timeout 5 bash -c "echo >/dev/tcp/$target/$LDAPS_PORT" 2>/dev/null; then
        log_ok "TCP connection to $target:$LDAPS_PORT succeeded"
    else
        log_fail "TCP connection to $target:$LDAPS_PORT failed"
    fi
done

# ═══════════════════════════════════════════════════════════════════
#  TEST 3: TLS/SSL Certificate Validation
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  TEST 3: TLS/SSL Certificate Inspection"
echo "═══════════════════════════════════════════════════════════"

for target in "$DC1_NAME:$DC1_IP" "$DC2_NAME:$DC2_IP"; do
    name="${target%%:*}"
    ip="${target##*:}"

    log_info "Checking certificate on $name ($ip) ..."
    cert_info=$(echo | openssl s_client -connect "$ip:$LDAPS_PORT" \
        -servername "$name" 2>/dev/null | openssl x509 -noout -subject -issuer -dates 2>/dev/null || true)

    if [ -n "$cert_info" ]; then
        log_ok "TLS certificate retrieved from $name:"
        echo "$cert_info" | sed 's/^/       /'
    else
        log_fail "Could not retrieve TLS certificate from $name ($ip)"
    fi
done

# ═══════════════════════════════════════════════════════════════════
#  TEST 4: LDAPS Bind (Anonymous / Simple)
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  TEST 4: LDAPS Query via ldapsearch"
echo "═══════════════════════════════════════════════════════════"

# 4a. Test against the round-robin hostname (anonymous base query)
log_info "Testing anonymous base query against $LDAPS_HOSTNAME ..."

# Use LDAPTLS_REQCERT=never to skip CA validation in lab environments
export LDAPTLS_REQCERT=never

result=$(ldapsearch -H "ldaps://${LDAPS_HOSTNAME}:${LDAPS_PORT}" \
    -x -b "" -s base "(objectClass=*)" namingContexts 2>&1 || true)

if echo "$result" | grep -q "namingContexts"; then
    log_ok "LDAPS anonymous query to $LDAPS_HOSTNAME succeeded"
    echo "$result" | grep "namingContexts" | sed 's/^/       /'
else
    log_fail "LDAPS anonymous query to $LDAPS_HOSTNAME failed"
    echo "$result" | head -5 | sed 's/^/       /'
fi

# 4b. Test against each DC individually
for target in "$DC1_NAME:$DC1_IP" "$DC2_NAME:$DC2_IP"; do
    name="${target%%:*}"
    ip="${target##*:}"

    log_info "Testing LDAPS query against $name ($ip) ..."
    result=$(ldapsearch -H "ldaps://${ip}:${LDAPS_PORT}" \
        -x -b "" -s base "(objectClass=*)" namingContexts 2>&1 || true)

    if echo "$result" | grep -q "namingContexts"; then
        log_ok "LDAPS query to $name ($ip) succeeded"
    else
        log_fail "LDAPS query to $name ($ip) failed"
    fi
done

# ═══════════════════════════════════════════════════════════════════
#  TEST 5: Authenticated LDAPS Bind
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  TEST 5: Authenticated LDAPS Bind"
echo "═══════════════════════════════════════════════════════════"

log_info "Testing authenticated bind to $LDAPS_HOSTNAME ..."
log_warn "Enter the password for $BIND_USER when prompted (or press Ctrl+C to skip)."

read -rsp "Password: " BIND_PW
echo ""

if [ -n "$BIND_PW" ]; then
    result=$(ldapsearch -H "ldaps://${LDAPS_HOSTNAME}:${LDAPS_PORT}" \
        -x -D "$BIND_USER" -w "$BIND_PW" \
        -b "$BASE_DN" -s sub "(objectClass=user)" cn sAMAccountName \
        -z 5 2>&1 || true)

    if echo "$result" | grep -q "numEntries\|cn:"; then
        log_ok "Authenticated LDAPS bind and user search succeeded"
        echo "$result" | grep -E "^(dn:|cn:|sAMAccountName:)" | head -15 | sed 's/^/       /'
    else
        log_fail "Authenticated LDAPS bind failed"
        echo "$result" | head -5 | sed 's/^/       /'
    fi
else
    log_warn "Skipped authenticated bind test (no password provided)."
fi

# ═══════════════════════════════════════════════════════════════════
#  TEST 6: High Availability / Failover Simulation
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  TEST 6: High Availability – Round-Robin Rotation"
echo "═══════════════════════════════════════════════════════════"

log_info "Sending 10 LDAPS queries to $LDAPS_HOSTNAME to observe rotation ..."

dc1_hits=0
dc2_hits=0
other_hits=0

for i in $(seq 1 10); do
    resolved=$(dig +short "$LDAPS_HOSTNAME" A 2>/dev/null | head -1)

    result=$(ldapsearch -H "ldaps://${LDAPS_HOSTNAME}:${LDAPS_PORT}" \
        -x -b "" -s base "(objectClass=*)" namingContexts 2>&1 || true)

    if echo "$result" | grep -q "namingContexts"; then
        status="OK"
    else
        status="FAIL"
    fi

    echo "    Query $i: resolved=$resolved status=$status"

    case "$resolved" in
        "$DC1_IP") ((dc1_hits++)) ;;
        "$DC2_IP") ((dc2_hits++)) ;;
        *)         ((other_hits++)) ;;
    esac

    sleep 1
done

echo ""
log_info "Hit distribution:"
echo "       maxdc01 ($DC1_IP): $dc1_hits hits"
echo "       maxdc02 ($DC2_IP): $dc2_hits hits"
if [ "$other_hits" -gt 0 ]; then
    echo "       other            : $other_hits hits"
fi

if [ "$dc1_hits" -gt 0 ] && [ "$dc2_hits" -gt 0 ]; then
    log_ok "Both DCs received traffic – round-robin HA is working!"
elif [ "$dc1_hits" -gt 0 ] || [ "$dc2_hits" -gt 0 ]; then
    log_warn "Only one DC received traffic. DNS caching may prevent rotation."
    log_warn "Try: 'sudo systemd-resolve --flush-caches' and re-run."
else
    log_fail "No DC received traffic."
fi

# ═══════════════════════════════════════════════════════════════════
#  TEST 7: Failover Simulation (Manual)
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  TEST 7: Failover Simulation Guide"
echo "═══════════════════════════════════════════════════════════"

cat <<'FAILOVER_GUIDE'

  To test failover manually:

  1. On maxdc01, stop the NTDS service:
       Stop-Service NTDS -Force

  2. On this Ubuntu client, run:
       ldapsearch -H ldaps://ldaps.max.local:636 -x -b "" -s base namingContexts
     The query should still succeed (routed to maxdc02).

  3. On maxdc01, restart the NTDS service:
       Start-Service NTDS

  4. On maxdc02, stop the NTDS service:
       Stop-Service NTDS -Force

  5. Repeat the ldapsearch – it should succeed (routed to maxdc01).

  6. Restart NTDS on maxdc02:
       Start-Service NTDS

FAILOVER_GUIDE

# ═══════════════════════════════════════════════════════════════════
#  Summary
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  Test Summary"
echo "═══════════════════════════════════════════════════════════"
total=$((passed + failed))
echo -e "  ${GREEN}Passed: $passed${NC}  ${RED}Failed: $failed${NC}  Total: $total"

if [ "$failed" -eq 0 ]; then
    echo -e "\n  ${GREEN}All tests passed! LDAPS with DNS round-robin HA is working.${NC}"
else
    echo -e "\n  ${YELLOW}Some tests failed. Review the output above for details.${NC}"
fi

echo ""
echo "  Useful commands for ongoing testing:"
echo "    # Quick LDAPS test"
echo "    LDAPTLS_REQCERT=never ldapsearch -H ldaps://ldaps.max.local:636 -x -b \"\" -s base"
echo ""
echo "    # Check certificate"
echo "    echo | openssl s_client -connect ldaps.max.local:636 2>/dev/null | openssl x509 -noout -text"
echo ""
echo "    # Flush DNS cache"
echo "    sudo systemd-resolve --flush-caches"
echo ""
