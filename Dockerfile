# syntax=docker/dockerfile:1.4
FROM linuxserver/wireguard

# Set environment variables
ENV PUID=1000 \
    PGID=1000 \
    TZ=America/Los_Angeles \
    LOG_CONFS=false \
    SOCKS_PORT=1080

# Configure sysctl settings
RUN echo "net.ipv4.conf.all.src_valid_mark=1" > /etc/sysctl.d/99-wireguard.conf

# Install necessary packages
RUN apk add --no-cache dante-server wget curl iptables

# Create Dante server configuration file
COPY <<EOF /etc/sockd.conf
logoutput: syslog
user.privileged: root
user.unprivileged: nobody

# The listening network interface or address.
internal: 0.0.0.0 port=${SOCKS_PORT}

# The proxying network interface or address.
external: wg0

# socks-rules determine what is proxied through the external interface.
socksmethod: none

# client-rules determine who can connect to the internal interface.
clientmethod: none

client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
}

socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
}
EOF

# Run sockd proxy as a service
RUN mkdir -p /etc/s6-overlay/s6-rc.d/svc-sockd
COPY <<EOF /etc/s6-overlay/s6-rc.d/svc-sockd/type
longrun
EOF

COPY <<EOF /etc/s6-overlay/s6-rc.d/svc-sockd/run
#!/usr/bin/with-contenv bash

# Allow established connections
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Allow loopback
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Allow incoming SOCKS connections
iptables -A INPUT -p tcp --dport ${SOCKS_PORT} -j ACCEPT

# Allow outbound traffic ONLY through WireGuard interface
iptables -A OUTPUT -o wg0 -j ACCEPT

# Start Dante server
sockd -f /etc/sockd.conf -p /var/run/sockd.pid
EOF

RUN touch /etc/s6-overlay/s6-rc.d/user/contents.d/svc-sockd && \
    mkdir -p /etc/s6-overlay/s6-rc.d/svc-sockd/dependencies.d && \
    chmod +x  /etc/s6-overlay/s6-rc.d/svc-sockd/run

# Expose the necessary port
EXPOSE ${SOCKS_PORT}

# Create a healthcheck script
COPY <<EOF /usr/local/bin/healthcheck.sh
#!/bin/sh
set -e

echo "Starting healthcheck..."

echo "Checking if WireGuard interface is up..."
if ! ip link show wg0 up > /dev/null 2>&1; then
    echo "FAILED: WireGuard interface (wg0) is not up"
    ip link show
    exit 1
fi
echo "OK: WireGuard interface is up"

echo "Checking if WireGuard has valid IP..."
if ! ip addr show wg0 | grep -q "inet "; then
    echo "FAILED: WireGuard interface has no valid IP"
    ip addr show wg0
    exit 1
fi
echo "OK: WireGuard has valid IP"

echo "Checking if SOCKS port is listening..."
if ! netstat -an | grep -q ":${SOCKS_PORT}.*LISTEN"; then
    echo "FAILED: SOCKS port ${SOCKS_PORT} is not listening"
    echo "Current listening ports:"
    netstat -an | grep LISTEN
    exit 1
fi
echo "OK: SOCKS port is listening"

echo "Checking WireGuard routing..."
# Check if the WireGuard routing rule exists
if ! ip rule show | grep -q "not from all fwmark 0xca6c lookup 51820"; then
    echo "FAILED: WireGuard routing rule is missing"
    echo "Current routing rules:"
    ip rule show
    exit 1
fi

# Check if the default route in table 51820 goes through wg0
if ! ip route show table 51820 | grep -q "^default.*dev wg0"; then
    echo "FAILED: Default route in table 51820 is not through WireGuard"
    echo "Current routes in table 51820:"
    ip route show table 51820
    exit 1
fi
echo "OK: WireGuard routing is correctly configured"

echo "All checks passed successfully!"
exit 0
EOF

RUN chmod +x /usr/local/bin/healthcheck.sh

# Set healthcheck
HEALTHCHECK --interval=1s --timeout=5s --start-period=10s --retries=3 \
    CMD /usr/local/bin/healthcheck.sh