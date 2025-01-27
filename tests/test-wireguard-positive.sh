#!/bin/bash
set -e

# Source common setup
source "$(dirname "$0")/common-setup.sh"

# Run setup
setup_network
generate_keys
create_configs
start_containers
wait_for_services || exit 1
SERVER_PID=$(setup_test_server)
install_test_tools

# Test WireGuard and SOCKS functionality
echo "Running positive path tests..."

# Test direct SOCKS proxy connection
echo "Testing SOCKS proxy connection..."
nc -z localhost 1080 || exit 1

# Test WireGuard connectivity
echo "Testing WireGuard connectivity..."
docker exec wg-client-socks-server ping -c 1 10.0.0.1 || exit 1

# Test SOCKS proxy through WireGuard
echo "Testing SOCKS proxy through WireGuard..."
curl -s --socks5-hostname localhost:1080 http://10.0.0.1:8080 || exit 1
curl -s -x socks5h://localhost:1080 http://10.0.0.1:8080 || exit 1
ALL_PROXY=socks5://localhost:1080 curl -s http://10.0.0.1:8080 || exit 1

echo "All positive path tests passed successfully!"

# Cleanup
cleanup $SERVER_PID 