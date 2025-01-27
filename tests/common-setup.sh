#!/bin/bash

# Common setup functions for WireGuard tests
setup_network() {
    echo "Setting up test network..."
    docker network create wg-test-net || true
}

generate_keys() {
    echo "Generating WireGuard keys..."
    SERVER_PRIVATE_KEY=$(wg genkey)
    SERVER_PUBLIC_KEY=$(echo "$SERVER_PRIVATE_KEY" | wg pubkey)
    CLIENT_PRIVATE_KEY=$(wg genkey)
    CLIENT_PUBLIC_KEY=$(echo "$CLIENT_PRIVATE_KEY" | wg pubkey)
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
}

start_containers() {
    echo "Starting containers..."
    cd /tmp/wg_client_config/wg_confs

    # Start WireGuard server
    docker run -d --name wg-server \
        --cap-add=NET_ADMIN \
        --privileged \
        --network wg-test-net \
        -v /tmp/wg-server.conf:/etc/wireguard/wg0.conf \
        linuxserver/wireguard

    # Start WireGuard client and SOCKS server
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
}

wait_for_services() {
    echo "Waiting for services to initialize..."
    TIMEOUT=30
    INTERVAL=1
    ELAPSED=0

    while [ $ELAPSED -lt $TIMEOUT ]; do
        if docker exec wg-client-socks-server netstat -ln | grep -q ":1080.*LISTEN" && \
           docker exec wg-client-socks-server wg show 2>/dev/null | grep -q "latest handshake"; then
            echo "Services are ready"
            return 0
        fi
        sleep $INTERVAL
        ELAPSED=$((ELAPSED + INTERVAL))
    done

    echo "Timeout waiting for services to initialize"
    return 1
}

setup_test_server() {
    echo "Setting up test HTTP server..."
    docker exec wg-server apk add --no-cache python3 curl
    docker exec wg-server sh -c "echo 'hello' > /tmp/index.html && cd /tmp && python3 -m http.server 8080" &
    SERVER_PID=$!
    sleep 5
    return $SERVER_PID
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
}

cleanup() {
    echo "Cleaning up..."
    kill $1 2>/dev/null || true
    docker rm -f wg-server wg-client-socks-server || true
    docker network rm wg-test-net || true
    rm -rf /tmp/wg-server.conf /tmp/wg_client_config || true
}

# Export variables and functions
export -f setup_network generate_keys create_configs start_containers wait_for_services setup_test_server install_test_tools cleanup 