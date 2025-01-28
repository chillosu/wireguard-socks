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
        echo "Last health check logs:"
        docker inspect wg-client-socks-server --format='{{json .State.Health}}' | jq -r '.Log[-1].Output'
        echo "Container logs:"
        docker logs wg-client-socks-server
        return 1
    fi
    return 0
}

test_socks_proxy() {
    local should_work=$1
    local message=${2:-"Testing SOCKS proxy connection..."}
    local test_url=${3:-"http://ipinfo.io"}
    
    echo "$message"
    if curl -s --connect-timeout 5 --socks5-hostname $WG_CLIENT_SOCKS_SERVER_IP:1080 "$test_url" > /dev/null 2>&1; then
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

run_command() {
    local cmd=$1
    local ignore_error=${2:-false}
    
    echo "Running command: $cmd"
    if ! eval "$cmd"; then
        if [ "$ignore_error" = "false" ]; then
            echo "ERROR: Command failed: $cmd"
            return 1
        else
            echo "Command failed but continuing as requested"
        fi
    fi
    return 0
}

restart_containers() {
    echo "Restarting containers with fresh state..."
    docker compose down -v
    docker compose up -d
    wait_for_services || return 1
    return 0
}

run_test_scenario() {
    local name=$1
    local setup_cmd=$2
    local expected_health=$3
    local should_work=${4:-false}
    local should_restart=${5:-false}
    local ignore_setup_error=${6:-false}
    
    echo "Test: $name"
    
    # Run setup command
    if [ -n "$setup_cmd" ]; then
        run_command "$setup_cmd" "$ignore_setup_error" || return 1
    fi
    
    # Test SOCKS proxy
    test_socks_proxy "$should_work" "Verifying SOCKS proxy behavior..." "http://10.0.0.1:8080" || return 1
    
    # Wait for expected health status
    wait_for_health_status "$expected_health" 30 || return 1
    
    # Restart containers if requested
    if [ "$should_restart" = "true" ]; then
        restart_containers || return 1
    fi
    
    return 0
} 