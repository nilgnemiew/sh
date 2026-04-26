#!/bin/bash

# NaiveProxy Universal Installer (Final Clean Version)
# Author: Manus
# Features: Forced Port 443, Auto Let's Encrypt SSL, Uninstall Support, BBR

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

function show_menu() {
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}   NaiveProxy Universal Installer      ${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e "1. 安装 NaiveProxy (443端口 + 权威证书)"
    echo -e "2. 卸载 NaiveProxy"
    echo -e "3. 退出"
    echo -e "${GREEN}========================================${NC}"
    read -p "请选择操作 [1-3]: " CHOICE
}

function check_root() {
    if [[ $EUID -ne 0 ]]; then
       echo -e "${RED}错误: 必须以 root 用户运行此脚本${NC}" 
       exit 1
    fi
}

function uninstall_naive() {
    echo -e "${YELLOW}正在卸载 NaiveProxy...${NC}"
    systemctl stop caddy > /dev/null 2>&1
    systemctl disable caddy > /dev/null 2>&1
    rm -f /etc/systemd/system/caddy.service
    systemctl daemon-reload
    rm -rf /etc/caddy
    rm -rf /var/www/html
    rm -f /usr/bin/caddy
    echo -e "${GREEN}卸载完成！${NC}"
}

function install_naive() {
    # 1. Interactive Inputs
    while true; do
        read -p "请输入您的域名 (必填): " DOMAIN
        if [ -z "$DOMAIN" ]; then
            echo -e "${RED}错误: 域名不能为空！${NC}"
        else
            break
        fi
    done

    PORT=443
    echo -e "${YELLOW}已锁定端口为: $PORT${NC}"

    read -p "请输入用户名 (默认: user): " USERNAME
    USERNAME=${USERNAME:-user}

    read -p "请输入密码 (默认: pass123456): " PASSWORD
    PASSWORD=${PASSWORD:-pass123456}

    # 2. System Optimization
    echo -e "${GREEN}正在优化系统网络设置 (BBR)...${NC}"
    if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    fi
    if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    fi
    sysctl -p > /dev/null 2>&1

    # 3. Install Dependencies
    echo -e "${GREEN}正在安装依赖...${NC}"
    apt update && apt install -y wget tar xz-utils curl jq 2>/dev/null

    # 4. Download Caddy with NaiveProxy
    echo -e "${GREEN}正在下载集成 NaiveProxy 模块的 Caddy...${NC}"
    CADDY_URL="https://github.com/klzgrad/forwardproxy/releases/download/v2.10.0-naive/caddy-forwardproxy-naive.tar.xz"
    wget -O caddy-naive.tar.xz $CADDY_URL
    tar -xf caddy-naive.tar.xz
    mv caddy-forwardproxy-naive/caddy /usr/bin/caddy
    chmod +x /usr/bin/caddy
    rm -rf caddy-forwardproxy-naive caddy-naive.tar.xz

    # 5. Setup Fake Site
    mkdir -p /var/www/html
    echo "<html><head><title>Welcome</title></head><body><h1>Site Under Construction</h1><p>Powered by Caddy</p></body></html>" > /var/www/html/index.html

    # 6. Create Caddyfile (Forced Let's Encrypt)
    mkdir -p /etc/caddy
    cat > /etc/caddy/Caddyfile <<EOF
{
    order forward_proxy before file_server
}
:$PORT, $DOMAIN:$PORT {
    tls admin@$DOMAIN
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

    # 7. Create Systemd Service
    cat > /etc/systemd/system/caddy.service <<EOF
[Unit]
Description=Caddy NaiveProxy Service
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=/etc/caddy
ExecStart=/usr/bin/caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576
LimitNPROC=512

[Install]
WantedBy=multi-user.target
EOF

    # 8. Start Service
    echo -e "${GREEN}正在启动服务并申请证书...${NC}"
    systemctl daemon-reload
    systemctl enable caddy
    systemctl start caddy

    # 9. Output Info
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}       NaiveProxy 安装成功！           ${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e "域名: ${YELLOW}$DOMAIN${NC}"
    echo -e "端口: ${YELLOW}$PORT${NC}"
    echo -e "用户名: ${YELLOW}$USERNAME${NC}"
    echo -e "密码: ${YELLOW}$PASSWORD${NC}"
    echo -e "证书: ${YELLOW}权威证书 (Let's Encrypt)${NC}"
    echo -e "客户端连接字符串: ${YELLOW}https://$USERNAME:$PASSWORD@$DOMAIN${NC}"
    echo -e "${GREEN}========================================${NC}"
}

# Main Logic
check_root
show_menu

case $CHOICE in
    1)
        install_naive
        ;;
    2)
        uninstall_naive
        ;;
    3)
        exit 0
        ;;
    *)
        echo -e "${RED}无效选项${NC}"
        ;;
esac
