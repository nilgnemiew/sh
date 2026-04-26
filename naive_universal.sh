#!/bin/bash

# NaiveProxy Universal Installer V3 (Optimized & Interactive)
# Author: Manus
# Features: Forced Domain Input, Auto IP Forwarding, BBR, Smart SSL, Subscription Link

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}   NaiveProxy Universal Installer V3   ${NC}"
echo -e "${GREEN}========================================${NC}"

# 1. Root Check
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Error: This script must be run as root${NC}" 
   exit 1
fi

# 2. Interactive Inputs
# Domain is now mandatory
while true; do
    read -p "Enter your Domain (Mandatory): " DOMAIN
    if [ -z "$DOMAIN" ]; then
        echo -e "${RED}Error: Domain cannot be empty!${NC}"
    else
        break
    fi
done

read -p "Enter Port (default: 443): " PORT
PORT=${PORT:-443}

read -p "Enter Username (default: user): " USERNAME
USERNAME=${USERNAME:-user}

read -p "Enter Password (default: pass123456): " PASSWORD
PASSWORD=${PASSWORD:-pass123456}

# 3. System Optimization
echo -e "${GREEN}Optimizing system network settings...${NC}"
if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
fi
if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
fi
sysctl -p > /dev/null 2>&1

# 4. Install Dependencies
echo -e "${GREEN}Installing dependencies...${NC}"
apt update && apt install -y wget tar xz-utils curl jq 2>/dev/null

# 5. Download Caddy with NaiveProxy
echo -e "${GREEN}Downloading Caddy with NaiveProxy module...${NC}"
CADDY_URL="https://github.com/klzgrad/forwardproxy/releases/download/v2.10.0-naive/caddy-forwardproxy-naive.tar.xz"
wget -O caddy-naive.tar.xz $CADDY_URL
tar -xf caddy-naive.tar.xz
mv caddy-forwardproxy-naive/caddy /usr/bin/caddy
chmod +x /usr/bin/caddy
rm -rf caddy-forwardproxy-naive caddy-naive.tar.xz

# 6. SSL Logic & Port Detection
SSL_CONFIG="tls internal"
INSECURE="1"

if [ "$PORT" == "443" ]; then
    OCCUPIED=$(ss -tulpn | grep -E ":80 |:443 " | grep -v "caddy" > /dev/null; echo $?)
    if [ "$OCCUPIED" -ne 0 ]; then
        echo -e "${GREEN}Port 443 is standard. Using Let's Encrypt SSL.${NC}"
        SSL_CONFIG="tls admin@$DOMAIN"
        INSECURE="0"
    else
        echo -e "${YELLOW}Port 80/443 occupied. Using Self-signed.${NC}"
    fi
else
    echo -e "${YELLOW}Non-standard port $PORT. Using Self-signed.${NC}"
fi

# 7. Setup Fake Site
mkdir -p /var/www/html
echo "<html><head><title>Welcome</title></head><body><h1>Site Under Construction</h1><p>Powered by Caddy</p></body></html>" > /var/www/html/index.html

# 8. Create Caddyfile
mkdir -p /etc/caddy
cat > /etc/caddy/Caddyfile <<EOF
{
    order forward_proxy before file_server
}
:$PORT, $DOMAIN:$PORT {
    $SSL_CONFIG
    forward_proxy {
        basic_auth $USERNAME $PASSWORD
        hide_ip
        hide_via
        probe_resistance
    }
    file_server {
        root /var/www/html
    }
}
EOF

# 9. Create Systemd Service
cat > /etc/systemd/system/caddy.service <<EOF
[Unit]
Description=Caddy NaiveProxy Service
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=simple
User=root
Group=root
ExecStart=/usr/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/bin/caddy reload --config /etc/caddy/Caddyfile
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

# 10. Start Service
echo -e "${GREEN}Starting service...${NC}"
systemctl daemon-reload
systemctl enable caddy
systemctl restart caddy

# 11. Final Output
echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}      Installation Successful!          ${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "Server: $DOMAIN"
echo -e "Port: $PORT"
echo -e "User: $USERNAME"
echo -e "Pass: $PASSWORD"
echo -e "SSL: $([[ "$INSECURE" == "1" ]] && echo "Self-signed (Insecure)" || echo "Official (Secure)")"

SUB_LINK="naive+https://$USERNAME:$PASSWORD@$DOMAIN:$PORT?insecure=$INSECURE#$DOMAIN"

echo -e "\n${YELLOW}Your Subscription Link:${NC}"
echo -e "${GREEN}$SUB_LINK${NC}"
echo -e "${GREEN}========================================${NC}"
