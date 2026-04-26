#!/bin/bash

# NaiveProxy Universal Installer (Interactive Version)
# Author: Manus
# Features: Interactive input with defaults, Auto SSL/Self-signed, Systemd support, Subscription link

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}   NaiveProxy Universal Installer      ${NC}"
echo -e "${GREEN}========================================${NC}"

# 1. Root Check
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Error: This script must be run as root${NC}" 
   exit 1
fi

# 2. Interactive Inputs with Defaults
read -p "Enter your Domain (default: bv.672048.xyz): " DOMAIN
DOMAIN=${DOMAIN:-bv.672048.xyz}

read -p "Enter Port (default: 443): " PORT
PORT=${PORT:-443}

read -p "Enter Username (default: user): " USERNAME
USERNAME=${USERNAME:-user}

read -p "Enter Password (default: pass123456): " PASSWORD
PASSWORD=${PASSWORD:-pass123456}

echo -e "\n${YELLOW}Configuration Summary:${NC}"
echo -e "Domain: $DOMAIN"
echo -e "Port: $PORT"
echo -e "User: $USERNAME"
echo -e "Pass: $PASSWORD"
echo -e "----------------------------------------"

# 3. Install Dependencies
echo -e "${GREEN}Installing dependencies...${NC}"
apt update && apt install -y wget tar xz-utils curl jq ss-utils net-tools 2>/dev/null || apt install -y wget tar xz-utils curl jq

# 4. Download Caddy with NaiveProxy
echo -e "${GREEN}Downloading Caddy with NaiveProxy module...${NC}"
CADDY_URL="https://github.com/klzgrad/forwardproxy/releases/download/v2.10.0-naive/caddy-forwardproxy-naive.tar.xz"
wget -O caddy-naive.tar.xz $CADDY_URL
tar -xf caddy-naive.tar.xz
mv caddy-forwardproxy-naive/caddy /usr/bin/caddy
chmod +x /usr/bin/caddy
rm -rf caddy-forwardproxy-naive caddy-naive.tar.xz

# 5. SSL Logic & Port Detection
SSL_CONFIG="tls internal"
INSECURE="1"

# Check if port 80 and 443 are free for Let's Encrypt
PORT_80_FREE=$(ss -tulpn | grep -E ":80 " > /dev/null; echo $?)
PORT_443_FREE=$(ss -tulpn | grep -E ":443 " > /dev/null; echo $?)

if [ "$PORT" == "443" ] && [ "$PORT_80_FREE" -ne 0 ] && [ "$PORT_443_FREE" -ne 0 ]; then
    echo -e "${GREEN}Port 443/80 available. Using Let's Encrypt SSL.${NC}"
    SSL_CONFIG="tls admin@$DOMAIN"
    INSECURE="0"
else
    echo -e "${YELLOW}Using Self-signed certificate (Port 80/443 occupied or non-standard port used).${NC}"
    SSL_CONFIG="tls internal"
    INSECURE="1"
fi

# 6. Setup Fake Site
mkdir -p /var/www/html
echo "<html><head><title>Welcome</title></head><body><h1>Site Under Construction</h1><p>Powered by Caddy</p></body></html>" > /var/www/html/index.html

# 7. Create Caddyfile
mkdir -p /etc/caddy
cat > /etc/caddy/Caddyfile <<EOF
{
    order forward_proxy before file_server
}
$DOMAIN:$PORT {
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

# 8. Create Systemd Service
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

# 9. Start Service
echo -e "${GREEN}Starting service...${NC}"
systemctl daemon-reload
systemctl enable caddy
systemctl restart caddy

# 10. Final Output & Subscription Link
echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}      Installation Successful!          ${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "Server: $DOMAIN"
echo -e "Port: $PORT"
echo -e "User: $USERNAME"
echo -e "Pass: $PASSWORD"
echo -e "SSL: $([[ "$INSECURE" == "1" ]] && echo "Self-signed (Insecure)" || echo "Official (Secure)")"

# Generate URL
SUB_LINK="naive+https://$USERNAME:$PASSWORD@$DOMAIN:$PORT?insecure=$INSECURE#$DOMAIN"

echo -e "\n${YELLOW}Your Subscription Link (Copy to Client):${NC}"
echo -e "${GREEN}$SUB_LINK${NC}"
echo -e "${GREEN}========================================${NC}"
