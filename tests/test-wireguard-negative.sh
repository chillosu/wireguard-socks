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

# Test 1: WireGuard down scenario
echo "Bringing WireGuard down for DNS testing..."
docker compose exec wg-client-socks-server wg-quick down wg0

# Test DNS resolution with WireGuard down to see raw DNS traffic
echo "Testing DNS resolution with WireGuard down..."

# Install tcpdump on host
echo "Installing tcpdump on host..."
apt-get update && apt-get install -y tcpdump

# Start tcpdump in background on host
echo "Starting DNS traffic capture on host..."
echo "Available interfaces:"
ip link show

echo "Starting capture on all interfaces..."
tcpdump -n -i any -v -s0 '(udp port 53 or tcp port 53)' > /tmp/dns_capture.txt 2>&1 &
TCPDUMP_PID=$!
sleep 2  # Give tcpdump time to start

echo "Host DNS configuration:"
cat /etc/resolv.conf

# Test DNS resolution with standard SOCKS5 (DNS resolved on host)
echo "Testing DNS resolution with standard SOCKS5 (host DNS)..."
docker run --rm --network wg-test-net curlimages/curl:latest \
    curl -v --socks5-hostname wg-client-socks-server:1080 \
    https://google.com 2>&1 | grep -E "DNS|SOCKS5|Resolved|Info:|HTTP/" || true

# Test DNS resolution with SOCKS5h (DNS resolved through proxy)
echo "Testing DNS resolution with SOCKS5h (proxy DNS)..."
docker run --rm --network wg-test-net curlimages/curl:latest \
    curl -v --proxy socks5h://wg-client-socks-server:1080 \
    https://google.com 2>&1 | grep -E "DNS|SOCKS5|Resolved|Info:|HTTP/" || true

# Stop tcpdump and show results
echo "Stopping DNS capture and showing results..."
kill $TCPDUMP_PID
sleep 1
echo "DNS traffic captured on host:"
cat /tmp/dns_capture.txt

# Now run the formal WireGuard down test which will restart everything
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