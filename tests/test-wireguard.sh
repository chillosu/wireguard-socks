#!/bin/bash
set -e

# Create a docker network for testing
docker network create wg-test-net

# Generate keys for server
SERVER_PRIVATE_KEY=$(wg genkey)
SERVER_PUBLIC_KEY=$(echo "$SERVER_PRIVATE_KEY" | wg pubkey)

# Generate keys for client
CLIENT_PRIVATE_KEY=$(wg genkey)
CLIENT_PUBLIC_KEY=$(echo "$CLIENT_PRIVATE_KEY" | wg pubkey)

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
# Change to the wg_confs directory
cd /tmp/wg_client_config/wg_confs

# Start WireGuard server in a container
docker run -d --name wg-server \
    --cap-add=NET_ADMIN \
    --privileged \
    --network wg-test-net \
    -v /tmp/wg-server.conf:/etc/wireguard/wg0.conf \
    linuxserver/wireguard

# Start our WireGuard client and socks servers
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

# Wait for services to be ready
echo "Waiting for services to initialize..."
TIMEOUT=30
INTERVAL=1
ELAPSED=0

while [ $ELAPSED -lt $TIMEOUT ]; do
    if docker exec wg-client-socks-server netstat -ln | grep -q ":1080.*LISTEN" && \
       docker exec wg-client-socks-server wg show 2>/dev/null | grep -q "latest handshake"; then
        echo "Services are ready"
        break
    fi
    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
done

if [ $ELAPSED -ge $TIMEOUT ]; then
    echo "Timeout waiting for services to initialize"
    exit 1
fi

# Start HTTP server on WireGuard server
echo "Starting Python HTTP server on WireGuard server (10.0.0.1:8080)..."
# First install the required packages
docker exec wg-server apk add --no-cache python3 curl
# Then start the server
docker exec wg-server sh -c "echo 'hello' > /tmp/index.html && cd /tmp && python3 -m http.server 8080" &
SERVER_PID=$!
sleep 5  # Give time for server to start

# Verify HTTP server is running
echo "Verifying HTTP server is running..."
docker exec wg-server sh -c "ps aux | grep '[p]ython.*8080'"
docker exec wg-server sh -c "netstat -ln | grep 8080"
echo "Testing server locally with different methods:"
docker exec wg-server sh -c "curl -s http://localhost:8080"
docker exec wg-server sh -c "curl -s http://127.0.0.1:8080"
docker exec wg-server sh -c "curl -s http://10.0.0.1:8080"
docker exec wg-server sh -c "nc -zv localhost 8080"

# Verify exact response content
echo -e "\nVerifying exact response content..."
RESPONSE=$(docker exec wg-server curl -s http://localhost:8080)
if [ "$RESPONSE" != "hello" ]; then
    echo "ERROR: Unexpected response content:"
    echo "Expected: 'hello'"
    echo "Got: '$RESPONSE'"
    exit 1
fi
echo "Response content verified successfully!"

# Install required tools if not present
echo "Installing required tools..."
apt-get update && apt-get install -y curl netcat-openbsd tsocks socat python3

# Configure tsocks to route through SOCKS proxy
cat > /etc/tsocks.conf << EOF
server = 127.0.0.1
server_port = 1080
server_type = 5
local = 0.0.0.0/0
EOF

# Debug: Show network configuration
echo -e "\nDebug: Network Configuration"
echo "Host network interfaces:"
ip addr show
echo -e "\nHost routing table:"
ip route
echo -e "\nWireGuard server network:"
docker exec wg-server ip addr show
docker exec wg-server ip route
echo -e "\nWireGuard client network:"
docker exec wg-client-socks-server ip addr show
docker exec wg-client-socks-server ip route

# Test direct connection to SOCKS proxy
echo "Testing direct connection to SOCKS proxy server..."
nc -z localhost 1080

echo "Testing SOCKS proxy connection to WireGuard server..."
curl -s --socks5-hostname localhost:1080 http://10.0.0.1:8080

# Only if local test succeeds, try external sites
if [ $? -eq 0 ]; then
    echo "Testing SOCKS proxy with public sites..."
    curl -s --socks5-hostname localhost:1080 https://ipinfo.io
fi

# Test WireGuard connectivity
echo "Testing WireGuard connectivity..."
docker exec wg-client-socks-server ping -c 1 10.0.0.1

echo "Testing HTTP server directly from WireGuard client:"
docker exec wg-client-socks-server sh -c "apk add --no-cache curl && curl -s http://10.0.0.1:8080"

# Test connection through SOCKS proxy to WireGuard server
echo "Testing connection through SOCKS proxy to WireGuard server..."

# Test with curl and explicit SOCKS5 proxy
echo "Testing with curl and SOCKS5 proxy:"
curl -s -x socks5://localhost:1080 http://10.0.0.1:8080

# Test with curl and SOCKS5h proxy (proxy does DNS resolution)
echo "Testing with curl and SOCKS5h proxy:"
curl -s -x socks5h://localhost:1080 http://10.0.0.1:8080

# Test with curl environment variables
echo "Testing with curl environment variables:"
ALL_PROXY=socks5://localhost:1080 curl -s http://10.0.0.1:8080

# Debug server status if all tests fail
if [ $? -ne 0 ]; then
    echo "Debug: Server Status"
    docker exec wg-server ps aux | grep python
    docker exec wg-server netstat -ln | grep 8080
    docker exec wg-server curl -s http://localhost:8080
    exit 1
fi

echo "All connectivity tests passed successfully!"

# Kill the HTTP server
kill $SERVER_PID 2>/dev/null || true

# Get final status
echo "Final Network Status:"
docker exec wg-server wg show
docker exec wg-client-socks-server wg show

# Cleanup
docker rm -f wg-server wg-client-socks-server
docker network rm wg-test-net
rm -rf /tmp/wg-server.conf /tmp/wg_client_config 