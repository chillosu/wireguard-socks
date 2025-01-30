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

echo "All positive path tests passed successfully!"

# Cleanup
cleanup 