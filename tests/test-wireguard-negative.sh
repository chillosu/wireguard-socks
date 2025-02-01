#!/bin/bash
set -e

# Source common setup and test functions
source "$(dirname "$0")/common-setup.sh"
source "$(dirname "$0")/test-functions.sh"

# Run setup
setup_network
generate_keys
create_configs
start_containers
wait_for_services || exit 1
SERVER_PID=$(setup_test_server)
install_test_tools

echo "Running negative path tests..."

# Bring WireGuard down for DNS testing
echo "Bringing WireGuard down for DNS testing..."
docker compose exec wg-client-socks-server wg-quick down wg0

# Test DNS resolution with WireGuard down to see raw DNS traffic
echo "Testing DNS resolution with WireGuard down..."

# Install tcpdump quietly
sudo apt-get update -qq
sudo apt-get install -qq -y tcpdump

# Start tcpdump in background on host
echo "Starting DNS traffic capture (WireGuard DOWN)..."
tcpdump -n -i eth0 'port 53 and not host 127.0.0.53 and not host 127.0.0.1' > /tmp/dns_capture_down.txt 2>&1 &
TCPDUMP_PID=$!
sleep 2

# Show only the current DNS server
echo "Current DNS server:"
resolvectl status eth0 | grep "Current DNS Server:"

# Generate DNS traffic
echo "Generating DNS queries..."
docker run --rm --network wg-test-net curlimages/curl:latest \
    curl -s --socks5-hostname wg-client-socks-server:1080 \
    https://google.com > /dev/null || true

# Stop tcpdump and show results
echo "Stopping DNS capture..."
kill $TCPDUMP_PID
sleep 1
echo "DNS traffic with WireGuard DOWN:"
grep -E "A\? |AAAA\? " /tmp/dns_capture_down.txt || true

# Restore system state and wait for WireGuard to be up
echo "Restoring system state..."
restart_containers || exit 1

# Now capture DNS with WireGuard up
echo "Starting DNS traffic capture (WireGuard UP)..."
tcpdump -n -i eth0 'port 53 and not host 127.0.0.53 and not host 127.0.0.1' > /tmp/dns_capture_up.txt 2>&1 &
TCPDUMP_PID=$!
sleep 2

# Generate DNS traffic again
echo "Generating DNS queries with WireGuard UP..."
docker run --rm --network wg-test-net curlimages/curl:latest \
    curl -s --socks5-hostname wg-client-socks-server:1080 \
    https://google.com > /dev/null || true

# Stop second tcpdump and show results
echo "Stopping DNS capture..."
kill $TCPDUMP_PID
sleep 1
echo "DNS traffic with WireGuard UP:"
grep -E "A\? |AAAA\? " /tmp/dns_capture_up.txt || true

# Now run the formal negative tests
echo "Running formal WireGuard down test..."
run_test_scenario \
    "WireGuard down scenario" \
    "docker compose exec wg-client-socks-server wg-quick down wg0" \
    "unhealthy" \
    "false" \
    "true" || exit 1

# Test 2: SOCKS daemon down scenario
run_test_scenario \
    "SOCKS daemon down scenario" \
    "docker compose exec wg-client-socks-server sh -c 's6-svc -d /run/service/svc-sockd && pkill sockd'" \
    "unhealthy" \
    "false" \
    "true" || exit 1

echo "All negative path tests passed successfully!"

# Cleanup
cleanup 