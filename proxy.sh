#!/bin/bash

### 基础路径
SB_DIR="/etc/sing-box"
CERT_DIR="$SB_DIR/cert"
SB_CONFIG="$SB_DIR/config.json"
KEY_FILE="$SB_DIR/reality.key"
SERVICE_FILE="/etc/systemd/system/sing-box.service"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

### root 检查
check_root() {
  [ "$EUID" -ne 0 ] && echo -e "${RED}请使用 root 执行${NC}" && exit 1
}

### 安装依赖
install_deps() {
  echo -e "${GREEN}正在安装依赖...${NC}"
  command -v jq >/dev/null || (apt update && apt install -y jq || yum install -y jq)
  command -v curl >/dev/null || (apt update && apt install -y curl || yum install -y curl)
  command -v openssl >/dev/null || (apt update && apt install -y openssl || yum install -y openssl)
}

### 安装 sing-box
install_singbox() {
  command -v sing-box >/dev/null || bash <(curl -fsSL https://sing-box.app/install.sh)
}

### 开启 BBR
enable_bbr() {
  grep -q bbr /etc/sysctl.conf || cat >> /etc/sysctl.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
  sysctl -p >/dev/null 2>&1
}

### 生成自签证书
gen_cert() {
  mkdir -p "$CERT_DIR"
  [ -f "$CERT_DIR/server.key" ] && return
  openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout "$CERT_DIR/server.key" \
    -out "$CERT_DIR/server.crt" \
    -days 3650 \
    -subj "/C=US/O=SingBox/CN=SingBox"
}

### 生成 Reality 密钥
gen_reality_key() {
  if [ ! -f "$KEY_FILE" ]; then
    sing-box generate reality-keypair > "$KEY_FILE"
  fi
}

### 端口检测
check_port() {
  ss -lntup | grep -q ":$1 " && return 1 || return 0
}

### 安装配置
install_all() {
  read -p "Hysteria2 端口 [默认 443]: " HY_PORT
  read -p "VLESS Reality 端口 [默认 8443]: " VL_PORT

  HY_PORT=${HY_PORT:-443}
  VL_PORT=${VL_PORT:-8443}

  echo -e "\n${GREEN}设置 Reality 伪装域名 (SNI):${NC}"
  read -p "请输入域名 (直接回车默认使用 www.microsoft.com): " INPUT_DOMAIN
  DOMAIN=${INPUT_DOMAIN:-www.microsoft.com}

  check_port $HY_PORT || { echo -e "${RED}端口 $HY_PORT 被占用${NC}"; return; }
  check_port $VL_PORT || { echo -e "${RED}端口 $VL_PORT 被占用${NC}"; return; }

  UUID=$(sing-box generate uuid)
  PASS=$(openssl rand -hex 8)
  SID=$(openssl rand -hex 4) 

  gen_cert
  gen_reality_key

  PRIV_KEY=$(awk '/PrivateKey/ {print $2}' "$KEY_FILE")

  mkdir -p "$SB_DIR"

cat > "$SB_CONFIG" <<EOF
{
  "log": { "level": "info" },
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "hy2",
      "listen": "::",
      "listen_port": $HY_PORT,
      "users": [{ "password": "$PASS" }],
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "$CERT_DIR/server.crt",
        "key_path": "$CERT_DIR/server.key"
      }
    },
    {
      "type": "vless",
      "tag": "reality",
      "listen": "::",
      "listen_port": $VL_PORT,
      "users": [{
        "uuid": "$UUID",
        "flow": "xtls-rprx-vision"
      }],
      "tls": {
        "enabled": true,
        "server_name": "$DOMAIN",
        "reality": {
          "enabled": true,
          "handshake": { "server": "$DOMAIN", "server_port": 443 },
          "private_key": "$PRIV_KEY",
          "short_id": ["$SID"]
        }
      }
    }
  ],
  "outbounds": [{ "type": "direct" }]
}
EOF

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=sing-box service
After=network.target

[Service]
ExecStart=/usr/bin/sing-box run -c $SB_CONFIG
Restart=on-failure
LimitNOFILE=51200

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable sing-box
  systemctl restart sing-box

  show_nodes
}

### 获取地区和服务商
get_info() {
  # --connect-timeout 限制连接时间，--retry 失败自动重试 2 次
  local info=$(curl -s --connect-timeout 5 --retry 2 http://ip-api.com/json/?fields=countryCode,isp)
  
  REGION=$(echo "$info" | jq -r '.countryCode // "UN"')
  ISP=$(echo "$info" | jq -r '.isp // "Unknown"' | tr ' ' '_')
}

### 输出节点
show_nodes() {
  IP=$(curl -s ipv4.ip.sb)
  get_info # 获取最新的地区和 ISP 信息

  HY_PORT=$(jq '.inbounds[]|select(.tag=="hy2")|.listen_port' $SB_CONFIG)
  VL_PORT=$(jq '.inbounds[]|select(.tag=="reality")|.listen_port' $SB_CONFIG)

  PASS=$(jq -r '.inbounds[]|select(.tag=="hy2")|.users[0].password' $SB_CONFIG)
  UUID=$(jq -r '.inbounds[]|select(.tag=="reality")|.users[0].uuid' $SB_CONFIG)

  DOMAIN=$(jq -r '.inbounds[]|select(.tag=="reality")|.tls.server_name' $SB_CONFIG)
  SID=$(jq -r '.inbounds[]|select(.tag=="reality")|.tls.reality.short_id[0]' $SB_CONFIG)
  PUB_KEY=$(awk '/PublicKey/ {print $2}' "$KEY_FILE")

  echo
  echo -e "${GREEN}===== 节点配置已生成 =====${NC}"
  echo
  echo -e "Hysteria2 (高速模式):"
  echo "hy2://$PASS@$IP:$HY_PORT/?insecure=1&alpn=h3#${REGION}-${ISP}"
  echo
  echo -e "VLESS Reality (稳健模式):"
  echo "vless://$UUID@$IP:$VL_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$DOMAIN&fp=chrome&pbk=$PUB_KEY&sid=$SID&type=tcp#${REGION}-${ISP}"
  echo
}

### 菜单 (略，同之前)
menu() {
  clear
  echo "========== sing-box 管理面板 (ISP 识别版) =========="
  echo "1. 安装 / 重装 (默认 SNI: Microsoft)"
  echo "2. 查看节点信息"
  echo "3. 运行状态"
  echo "4. 实时日志"
  echo "5. 重启服务"
  echo "6. 彻底卸载"
  echo "0. 退出"
  read -p "请选择 [0-6]: " num

  case $num in
    1) install_deps; install_singbox; enable_bbr; install_all ;;
    2) [ -f "$SB_CONFIG" ] && show_nodes || echo "请先安装";;
    3) systemctl status sing-box ;;
    4) journalctl -u sing-box -f ;;
    5) systemctl restart sing-box ;;
    6) systemctl stop sing-box; rm -rf $SB_DIR $SERVICE_FILE; echo "已卸载";;
    0) exit ;;
  esac
}

check_root
menu
