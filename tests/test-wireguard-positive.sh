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

echo "Running positive path tests..."

# Test direct SOCKS proxy connection from host
echo "Testing SOCKS proxy connection from host..."
nc -z $WG_CLIENT_SOCKS_SERVER_IP 1080 || exit 1

# Test WireGuard connectivity and SOCKS proxy functionality
run_test_scenario \
    "WireGuard connectivity and SOCKS proxy functionality" \
    "docker compose exec wg-client-socks-server ping -c 1 10.0.0.1" \
    "healthy" \
    "true" || exit 1

# Test SOCKS proxy through WireGuard from another container
echo "Testing SOCKS proxy through WireGuard from container..."
docker run --rm --network wg-test-net curlimages/curl:latest \
    curl -s --socks5-hostname wg-client-socks-server:1080 http://10.0.0.1:8080 || exit 1

# Test DNS resolution through SOCKS proxy
echo "Testing DNS resolution through SOCKS proxy..."

# Install tcpdump on host
echo "Installing tcpdump on host..."
apt-get update && apt-get install -y tcpdump

# Start tcpdump in background on host
echo "Starting DNS traffic capture on host..."
tcpdump -n -i any -v -s0 'udp port 53 or tcp port 53' > /tmp/dns_capture.txt 2>&1 &
TCPDUMP_PID=$!
sleep 2  # Give tcpdump time to start

# Test DNS resolution with standard SOCKS5 (DNS resolved on host)
echo "Testing DNS resolution with standard SOCKS5 (host DNS)..."
docker run --rm --network wg-test-net curlimages/curl:latest \
    curl -v --socks5-hostname wg-client-socks-server:1080 \
    https://google.com 2>&1 | grep -E "DNS|SOCKS5|Resolved|Info:|HTTP/" || exit 1

# Test DNS resolution with SOCKS5h (DNS resolved through proxy)
echo "Testing DNS resolution with SOCKS5h (proxy DNS)..."
docker run --rm --network wg-test-net curlimages/curl:latest \
    curl -v --proxy socks5h://wg-client-socks-server:1080 \
    https://google.com 2>&1 | grep -E "DNS|SOCKS5|Resolved|Info:|HTTP/" || exit 1

# Stop tcpdump and show results
echo "Stopping DNS capture and showing results..."
kill $TCPDUMP_PID
sleep 1
echo "DNS traffic captured on host:"
cat /tmp/dns_capture.txt

echo "All positive path tests passed successfully!"

# Cleanup
cleanup 