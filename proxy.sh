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
  command -v jq >/dev/null || (apt install -y jq || yum install -y jq)
  command -v curl >/dev/null || (apt install -y curl || yum install -y curl)
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

### 生成 Reality 密钥（只生成一次）
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
  read -p "Reality 伪装域名（默认 www.cloudflare.com）: " DOMAIN

  HY_PORT=${HY_PORT:-443}
  VL_PORT=${VL_PORT:-8443}
  DOMAIN=${DOMAIN:-www.cloudflare.com}

  check_port $HY_PORT || { echo "端口 $HY_PORT 被占用"; return; }
  check_port $VL_PORT || { echo "端口 $VL_PORT 被占用"; return; }

  UUID=$(sing-box generate uuid)
  PASS=$(openssl rand -hex 8)

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
          "short_id": ["abcd1234"]
        }
      }
    }
  ],
  "outbounds": [{ "type": "direct" }]
}
EOF

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=sing-box
After=network.target

[Service]
ExecStart=/usr/bin/sing-box run -c $SB_CONFIG
Restart=on-failure
LimitNOFILE=51200

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reexec
  systemctl daemon-reload
  systemctl enable sing-box
  systemctl restart sing-box

  show_nodes
}

### 获取节点地区
get_ip_region() {
  local region
  region=$(curl -s --max-time 3 https://ip.sb/country_code)
  if [[ -z "$region" || ${#region} -ne 2 ]]; then
    region="UN"
  fi
  echo "$region"
}

### 修改端口
change_port() {
  OLD_HY=$(jq '.inbounds[]|select(.tag=="hy2")|.listen_port' $SB_CONFIG)
  OLD_VL=$(jq '.inbounds[]|select(.tag=="reality")|.listen_port' $SB_CONFIG)

  echo "当前 Hysteria2 端口: $OLD_HY"
  echo "当前 VLESS Reality 端口: $OLD_VL"

  read -p "新 Hysteria2 端口（回车不改）: " NH
  read -p "新 VLESS 端口（回车不改）: " NV

  [ -n "$NH" ] && check_port $NH && \
    jq ".inbounds |= map(if .tag==\"hy2\" then .listen_port=$NH else . end)" \
    $SB_CONFIG > /tmp/sb && mv /tmp/sb $SB_CONFIG

  [ -n "$NV" ] && check_port $NV && \
    jq ".inbounds |= map(if .tag==\"reality\" then .listen_port=$NV else . end)" \
    $SB_CONFIG > /tmp/sb && mv /tmp/sb $SB_CONFIG

  systemctl restart sing-box
  show_nodes
}

### 输出节点
show_nodes() {
  IP=$(curl -s ipv4.ip.sb)
  REGION=$(get_ip_region)

  HY_PORT=$(jq '.inbounds[]|select(.tag=="hy2")|.listen_port' $SB_CONFIG)
  VL_PORT=$(jq '.inbounds[]|select(.tag=="reality")|.listen_port' $SB_CONFIG)

  PASS=$(jq -r '.inbounds[]|select(.tag=="hy2")|.users[0].password' $SB_CONFIG)
  UUID=$(jq -r '.inbounds[]|select(.tag=="reality")|.users[0].uuid' $SB_CONFIG)

  DOMAIN=$(jq -r '.inbounds[]|select(.tag=="reality")|.tls.server_name' $SB_CONFIG)
  PUB_KEY=$(awk '/PublicKey/ {print $2}' "$KEY_FILE")

  echo
  echo "===== 节点信息 ====="
  echo

  echo "Hysteria2："
  echo "hy2://$PASS@$IP:$HY_PORT/?insecure=1&alpn=h3#${REGION}-HY2"
  echo

  echo "VLESS Reality："
  echo "vless://$UUID@$IP:$VL_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$DOMAIN&fp=chrome&pbk=$PUB_KEY&sid=abcd1234&type=tcp#${REGION}-Reality"
  echo
}

### 菜单
menu() {
  clear
  echo "========== sing-box 面板 =========="
  echo "1. 安装 / 重装（含 BBR）"
  echo "2. 查看节点"
  echo "3. 修改端口"
  echo "4. 查看状态"
  echo "5. 查看日志"
  echo "6. 重启服务"
  echo "7. 卸载"
  echo "0. 退出"
  read -p "选择: " num

  case $num in
    1) install_deps; install_singbox; enable_bbr; install_all ;;
    2) show_nodes ;;
    3) change_port ;;
    4) systemctl status sing-box ;;
    5) journalctl -u sing-box -f ;;
    6) systemctl restart sing-box ;;
    7) systemctl stop sing-box; rm -rf $SB_DIR $SERVICE_FILE ;;
    0) exit ;;
  esac
}

check_root
menu
