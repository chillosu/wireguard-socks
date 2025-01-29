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