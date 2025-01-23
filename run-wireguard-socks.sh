#!/bin/bash

# Default values
NAME=${1:-wireguard-socks}
CONFIG_PATH=${2:-$HOME/keepsolid/config/wireguard}
SOCKS_PORT=${3:-1080}
WIREGUARD_PORT=${4:-51820}

docker run -d \
  --name=$NAME \
  --cap-add=NET_ADMIN \
  --restart=always \
  -e TZ=$(timedatectl show --property=Timezone --value 2>/dev/null || cat /etc/timezone) \
  -e LOG_CONFS=true \
  -p $SOCKS_PORT:1080 \
  -p $WIREGUARD_PORT:51820/udp \
  --dns="1.1.1.1" \
  -v "$CONFIG_PATH:/config" \
  --sysctl="net.ipv4.conf.all.src_valid_mark=1" \
  chillosu/wireguard-socks 