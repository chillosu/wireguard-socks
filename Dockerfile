# syntax=docker/dockerfile:1.4
FROM linuxserver/wireguard

# Set environment variables
ENV PUID=1000 \
    PGID=1000 \
    TZ=America/Los_Angeles \
    LOG_CONFS=false \
    DNS=1.1.1.1 \
    SOCKS_PORT=1080 \
    WIREGUARD_PORT=51820

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

# Wait for WireGuard interface to be up
while ! ip link show wg0 up > /dev/null 2>&1; do
    sleep 1
done

# Ensure proper routing
iptables -t nat -A POSTROUTING -o wg0 -j MASQUERADE
iptables -A FORWARD -i wg0 -j ACCEPT
iptables -A FORWARD -o wg0 -j ACCEPT

# Add route for SOCKS traffic
ip route add default dev wg0 table 200
ip rule add fwmark 0x1 table 200

# Start Dante server
sockd -f /etc/sockd.conf -p /var/run/sockd.pid
EOF

RUN touch /etc/s6-overlay/s6-rc.d/user/contents.d/svc-sockd && \
    mkdir -p /etc/s6-overlay/s6-rc.d/svc-sockd/dependencies.d && \
    chmod +x  /etc/s6-overlay/s6-rc.d/svc-sockd/run

# Expose the necessary port
EXPOSE ${SOCKS_PORT}
EXPOSE ${WIREGUARD_PORT}/udp

# Create a healthcheck script
COPY <<EOF /usr/local/bin/healthcheck.sh
#!/bin/sh
set -e

# Check if WireGuard interface is up
if ! ip link show wg0 up > /dev/null 2>&1; then
    exit 1
fi

# Check if WireGuard has a valid IP
if ! ip addr show wg0 | grep -q "inet "; then
    exit 1
fi

# Check if SOCKS port is listening
if ! netstat -an | grep -q ":${SOCKS_PORT}.*LISTEN"; then
    exit 1
fi

exit 0
EOF

RUN chmod +x /usr/local/bin/healthcheck.sh

# Set healthcheck
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD /usr/local/bin/healthcheck.sh