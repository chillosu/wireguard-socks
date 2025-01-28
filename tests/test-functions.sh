#!/bin/bash

# Common test functions

wait_for_health_status() {
    local expected_status=$1
    local timeout=${2:-30}
    local message=${3:-"Waiting up to $timeout seconds for container to become $expected_status..."}
    
    echo "$message"
    local elapsed=0
    local status_found=false

    while [ $elapsed -lt $timeout ]; do
        local health_status=$(docker inspect wg-client-socks-server --format '{{.State.Health.Status}}')
        if [ "$health_status" = "$expected_status" ]; then
            status_found=true
            echo "Container is now $expected_status as expected"
            break
        fi
        sleep 1
        elapsed=$((elapsed + 1))
        echo "Current health status: $health_status (${elapsed}s elapsed)"
    done

    if [ "$status_found" = false ]; then
        echo "ERROR: Container did not become $expected_status within ${timeout} seconds!"
        echo "Final health status: $health_status"
        return 1
    fi
    return 0
}

test_socks_proxy() {
    local should_work=$1
    local message=${2:-"Testing SOCKS proxy connection..."}
    
    echo "$message"
    if curl -s --connect-timeout 5 --socks5-hostname $WG_CLIENT_SOCKS_SERVER_IP:1080 http://ipinfo.io > /dev/null 2>&1; then
        if [ "$should_work" = "false" ]; then
            echo "ERROR: SOCKS proxy should not work!"
            return 1
        fi
        echo "SOCKS proxy is working as expected"
    else
        if [ "$should_work" = "true" ]; then
            echo "ERROR: SOCKS proxy should be working!"
            return 1
        fi
        echo "SOCKS proxy is not working as expected"
    fi
    return 0
}

run_test_scenario() {
    local name=$1
    local setup_cmd=$2
    local expected_health=$3
    local should_work=${4:-false}
    local cleanup_cmd=${5:-""}
    
    echo "Test: $name"
    
    # Run setup command
    if [ -n "$setup_cmd" ]; then
        echo "Running setup: $setup_cmd"
        eval "$setup_cmd"
    fi
    
    # Test SOCKS proxy
    test_socks_proxy "$should_work" "Verifying SOCKS proxy behavior..." || return 1
    
    # Wait for expected health status
    wait_for_health_status "$expected_health" 30 || return 1
    
    # Run cleanup command if provided
    if [ -n "$cleanup_cmd" ]; then
        echo "Running cleanup: $cleanup_cmd"
        eval "$cleanup_cmd"
    fi
    
    return 0
} 