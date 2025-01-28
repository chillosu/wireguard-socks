#!/bin/bash

# Enable debug output
set -x

# Common setup functions for WireGuard tests
setup_network() {
    echo "Setting up test network..."
    docker network create wg-test-net || true
    echo "Network created, listing networks:"
    docker network ls
}

generate_keys() {
    echo "Generating WireGuard keys..."
    SERVER_PRIVATE_KEY=$(wg genkey)
    SERVER_PUBLIC_KEY=$(echo "$SERVER_PRIVATE_KEY" | wg pubkey)
    CLIENT_PRIVATE_KEY=$(wg genkey)
    CLIENT_PUBLIC_KEY=$(echo "$CLIENT_PRIVATE_KEY" | wg pubkey)
    echo "Keys generated successfully"
}

create_configs() {
    echo "Creating WireGuard configs..."
    # Create server config
    cat > /tmp/wg-server.conf << EOF
[Interface]
PrivateKey = $SERVER_PRIVATE_KEY
Address = 10.0.0.1/24
ListenPort = 51820
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o eth+ -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o eth+ -j MASQUERADE

[Peer]
PublicKey = $CLIENT_PUBLIC_KEY
AllowedIPs = 10.0.0.2/32
EOF

    # Create client config
    mkdir -p /tmp/wg_client_config/wg_confs
    cat > /tmp/wg_client_config/wg_confs/wg0.conf << EOF
[Interface]
PrivateKey = $CLIENT_PRIVATE_KEY
Address = 10.0.0.2/24

[Peer]
PublicKey = $SERVER_PUBLIC_KEY
Endpoint = wg-server:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
    echo "Configs created successfully"
    echo "Server config:"
    cat /tmp/wg-server.conf | grep -v PrivateKey
    echo "Client config:"
    cat /tmp/wg_client_config/wg_confs/wg0.conf | grep -v PrivateKey
}

start_containers() {
    echo "Starting containers..."
    cd /tmp/wg_client_config/wg_confs

    echo "Starting WireGuard server..."
    docker run -d --name wg-server \
        --cap-add=NET_ADMIN \
        --privileged \
        --network wg-test-net \
        -v /tmp/wg-server.conf:/etc/wireguard/wg0.conf \
        linuxserver/wireguard

    echo "WireGuard server container status:"
    docker ps -a | grep wg-server
    docker logs wg-server

    echo "Starting WireGuard client and SOCKS server..."
    docker run -d --name wg-client-socks-server \
        --cap-add=NET_ADMIN \
        --network wg-test-net \
        --privileged \
        --sysctl="net.ipv4.conf.all.src_valid_mark=1" \
        -e LOG_CONFS=false \
        -e PUID=1000 \
        -e PGID=1000 \
        -e TZ=UTC \
        --dns=1.1.1.1 \
        -p 1080:1080 \
        -v ".:/config/wg_confs" \
        wireguard-socks:local

    echo "WireGuard client container status:"
    docker ps -a | grep wg-client-socks-server
    docker logs wg-client-socks-server
}

wait_for_services() {
    echo "Waiting for services to initialize..."
    TIMEOUT=30
    INTERVAL=1
    ELAPSED=0

    while [ $ELAPSED -lt $TIMEOUT ]; do
        echo "Checking services (${ELAPSED}s elapsed)..."
        
        echo "SOCKS port status:"
        docker exec wg-client-socks-server netstat -ln || true
        
        echo "WireGuard status:"
        docker exec wg-client-socks-server wg show || true
        
        if docker exec wg-client-socks-server netstat -ln | grep -q ":1080.*LISTEN" && \
           docker exec wg-client-socks-server wg show 2>/dev/null | grep -q "latest handshake"; then
            echo "Services are ready"
            echo "Network interfaces:"
            docker exec wg-client-socks-server ip addr show
            return 0
        fi
        sleep $INTERVAL
        ELAPSED=$((ELAPSED + INTERVAL))
    done

    echo "Timeout waiting for services to initialize"
    echo "Final container states:"
    docker ps -a
    echo "WireGuard server logs:"
    docker logs wg-server
    echo "WireGuard client logs:"
    docker logs wg-client-socks-server
    return 1
}

setup_test_server() {
    echo "Setting up test HTTP server..."
    # Install required packages
    docker exec wg-server apk add --no-cache python3 curl

    # Create test file and start server in the container
    docker exec wg-server sh -c 'echo "hello" > /tmp/index.html'
    docker exec -d wg-server sh -c 'cd /tmp && python3 -m http.server 8080'

    # Wait for server to start
    echo "Waiting for HTTP server to start..."
    TIMEOUT=10
    ELAPSED=0
    while [ $ELAPSED -lt $TIMEOUT ]; do
        if docker exec wg-server netstat -ln | grep -q ":8080.*LISTEN"; then
            echo "HTTP server is running"
            # Test the server
            if docker exec wg-server curl -s http://localhost:8080 | grep -q "hello"; then
                echo "HTTP server is responding correctly"
                return 0
            fi
        fi
        sleep 1
        ELAPSED=$((ELAPSED + 1))
    done

    echo "Failed to start HTTP server"
    docker exec wg-server ps aux
    docker exec wg-server netstat -ln
    return 1
}

install_test_tools() {
    echo "Installing test tools..."
    apt-get update && apt-get install -y curl netcat-openbsd tsocks socat python3

    # Configure tsocks
    cat > /etc/tsocks.conf << EOF
server = 127.0.0.1
server_port = 1080
server_type = 5
local = 0.0.0.0/0
EOF
    echo "Test tools installed successfully"
}

cleanup() {
    echo "Cleaning up..."
    docker rm -f wg-server wg-client-socks-server || true
    docker network rm wg-test-net || true
    rm -rf /tmp/wg-server.conf /tmp/wg_client_config || true
    echo "Cleanup completed"
}

# Export variables and functions
export -f setup_network generate_keys create_configs start_containers wait_for_services setup_test_server install_test_tools cleanup 