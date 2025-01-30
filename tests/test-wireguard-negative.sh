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

# Install tcpdump on host
echo "Installing tcpdump on host..."
apt-get update && apt-get install -y tcpdump

# Start tcpdump in background on host
echo "Starting DNS traffic capture on host..."
echo "Available interfaces:"
ip link show

echo "Starting capture of upstream DNS traffic (excluding local resolver)..."
tcpdump -n -i eth0 -v -s0 'port 53 and not host 127.0.0.53 and not host 127.0.0.1' > /tmp/dns_capture.txt 2>&1 &
TCPDUMP_PID=$!
sleep 2  # Give tcpdump time to start

# Show DNS configuration details
echo "Host DNS configuration:"
cat /etc/resolv.conf
echo "Systemd resolved status:"
resolvectl status

# Generate DNS traffic with both SOCKS modes
echo "Generating DNS traffic with standard SOCKS5..."
docker run --rm --network wg-test-net curlimages/curl:latest \
    curl -s --socks5-hostname wg-client-socks-server:1080 \
    https://google.com > /dev/null || true

echo "Generating DNS traffic with SOCKS5h..."
docker run --rm --network wg-test-net curlimages/curl:latest \
    curl -s --proxy socks5h://wg-client-socks-server:1080 \
    https://google.com > /dev/null || true

# Stop tcpdump and show results
echo "Stopping DNS capture and showing results..."
kill $TCPDUMP_PID
sleep 1
echo "DNS traffic captured on host:"
cat /tmp/dns_capture.txt

# Restore system state after DNS testing
echo "Restoring system state..."
restart_containers || exit 1

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