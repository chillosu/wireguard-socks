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

echo "Running negative path tests..."

# Test WireGuard down scenario
echo "Testing SOCKS behavior when WireGuard is disconnected..."
docker exec wg-client-socks-server wg-quick down wg0

# Verify SOCKS fails when WireGuard is down
echo "Verifying SOCKS proxy fails when WireGuard is down..."
if curl -s --connect-timeout 5 --socks5-hostname $SOCKS_IP:1080 http://example.com > /dev/null 2>&1; then
    echo "ERROR: SOCKS proxy should not work when WireGuard is down!"
    cleanup
    exit 1
fi
echo "Confirmed: SOCKS proxy correctly fails when WireGuard is down"

# Wait for container to become unhealthy
echo "Waiting up to 30 seconds for container to become unhealthy..."
TIMEOUT=30
ELAPSED=0
UNHEALTHY=false

while [ $ELAPSED -lt $TIMEOUT ]; do
    HEALTH_STATUS=$(docker inspect --format='{{.State.Health.Status}}' wg-client-socks-server)
    if [ "$HEALTH_STATUS" = "unhealthy" ]; then
        UNHEALTHY=true
        echo "Container is now unhealthy as expected"
        break
    fi
    sleep 1
    ELAPSED=$((ELAPSED + 1))
    echo "Current health status: $HEALTH_STATUS (${ELAPSED}s elapsed)"
done

if [ "$UNHEALTHY" = false ]; then
    echo "ERROR: Container did not become unhealthy within ${TIMEOUT} seconds!"
    echo "Final health status: $HEALTH_STATUS"
    cleanup
    exit 1
fi

echo "All negative path tests passed successfully!"

# Cleanup
cleanup 