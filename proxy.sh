#!/bin/bash
### 基础路径
SB_DIR="/etc/sing-box"
CERT_DIR="$SB_DIR/cert"
SB_CONFIG="$SB_DIR/config.json"
KEY_FILE="$SB_DIR/reality.key"
SERVICE_FILE="/etc/systemd/system/sing-box.service"
ARGO_SERVICE="/etc/systemd/system/cloudflared-argo.service"
ARGO_DOMAIN_FILE="$SB_DIR/argo_domain.txt"
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'
CUSTOM_NAME="SingBox"

### 固定配置值
FIXED_VLESS_UUID="93be88a8-1880-4359-90af-fd2d266a9863"
FIXED_HY2_PASS="cc4b969259d0eb84"
FIXED_REALITY_SHORTID="b631f62d"
FIXED_REALITY_PUBKEY="y4_s_qNaoQdxwD91KAZOHlpLcJpaSy0RBVflQv4-Zlw"
FIXED_REALITY_PRIVKEY="SNpaGKzmrS131QIPhl92ato75liiD2_a12EomxDBz3U"

### 默认值
DEFAULT_WS_LOCAL_PORT=8080
DEFAULT_WS_PATH="/ws"

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

### 安装 cloudflared
install_cloudflared() {
  if command -v cloudflared >/dev/null; then
    return
  fi
  echo -e "${GREEN}正在安装 cloudflared (Argo Tunnel)...${NC}"
  ARCH=$(uname -m)
  if [ "$ARCH" = "x86_64" ]; then
    CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
  elif [ "$ARCH" = "aarch64" ]; then
    CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"
  else
    echo -e "${RED}不支持的架构: $ARCH${NC}"
    exit 1
  fi
  wget -q "$CF_URL" -O /usr/local/bin/cloudflared
  chmod +x /usr/local/bin/cloudflared
}

### 开启 BBR
enable_bbr() {
  grep -q bbr /etc/sysctl.conf || cat >> /etc/sysctl.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
  sysctl -p >/dev/null 2>&1
}

### 生成自签证书（仅 Hysteria2 使用）
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
  mkdir -p "$SB_DIR"
  if [ ! -f "$KEY_FILE" ]; then
    echo -e "${GREEN}写入固定 Reality 密钥对...${NC}"
    cat > "$KEY_FILE" <<EOF
PrivateKey: $FIXED_REALITY_PRIVKEY
PublicKey: $FIXED_REALITY_PUBKEY
EOF
    chmod 600 "$KEY_FILE"
  fi
}

### 端口检测
check_port() {
  ss -lntup | grep -q ":$1 " && return 1 || return 0
}

### 安装配置（Argo Quick Tunnel 版）
install_all() {
  read -p "Hysteria2 端口 [默认 443]: " HY_PORT
  read -p "VLESS Reality 端口 [默认 8443]: " VL_PORT
  read -p "自定义节点名称 [默认 SingBox]: " INPUT_NAME
  HY_PORT=${HY_PORT:-443}
  VL_PORT=${VL_PORT:-8443}
  CUSTOM_NAME=${INPUT_NAME:-SingBox}

  echo -e "\n${GREEN}设置 Reality 伪装域名 (SNI):${NC}"
  read -p "请输入域名 (直接回车默认 www.microsoft.com): " INPUT_DOMAIN
  DOMAIN=${INPUT_DOMAIN:-www.microsoft.com}

  # Argo WS 配置
  echo -e "\n${GREEN}===== Argo Quick Tunnel 配置 =====${NC}"
  echo -e "${YELLOW}WS 节点将使用 Cloudflare Quick Tunnel（零端口暴露）${NC}"
  read -p "WS 本地监听端口 (Argo 内部使用) [默认 $DEFAULT_WS_LOCAL_PORT]: " WS_LOCAL_PORT
  read -p "WebSocket 路径 [默认 $DEFAULT_WS_PATH]: " WS_PATH
  WS_LOCAL_PORT=${WS_LOCAL_PORT:-$DEFAULT_WS_LOCAL_PORT}
  WS_PATH=${WS_PATH:-$DEFAULT_WS_PATH}

  check_port $HY_PORT || { echo -e "${RED}端口 $HY_PORT 被占用${NC}"; return; }
  check_port $VL_PORT || { echo -e "${RED}端口 $VL_PORT 被占用${NC}"; return; }

  UUID="$FIXED_VLESS_UUID"
  PASS="$FIXED_HY2_PASS"
  SID="$FIXED_REALITY_SHORTID"
  gen_cert
  gen_reality_key
  PRIV_KEY="$FIXED_REALITY_PRIVKEY"

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
    },
    {
      "type": "vless",
      "tag": "vless-ws-argo",
      "listen": "127.0.0.1",
      "listen_port": $WS_LOCAL_PORT,
      "users": [{
        "uuid": "$UUID"
      }],
      "transport": {
        "type": "ws",
        "path": "$WS_PATH"
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

  # 安装并启动 Argo Quick Tunnel
  install_cloudflared

cat > "$ARGO_SERVICE" <<EOF
[Unit]
Description=Cloudflare Quick Tunnel for sing-box WS
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/cloudflared tunnel --url http://127.0.0.1:$WS_LOCAL_PORT
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable cloudflared-argo
  systemctl restart cloudflared-argo

  # 尝试获取 Argo 域名
  sleep 10
  ARGO_URL=$(journalctl -u cloudflared-argo --since "2 min ago" --no-pager | grep -o 'https://[^ ]*\.trycloudflare\.com' | tail -1)
  if [ -n "$ARGO_URL" ]; then
    echo "$ARGO_URL" > "$ARGO_DOMAIN_FILE"
    echo -e "${GREEN}Argo Quick Tunnel 已启动！${NC}"
    echo -e "临时域名: ${YELLOW}$ARGO_URL${NC}"
  else
    echo -e "${YELLOW}未能自动捕获 Argo 域名，请稍后运行: journalctl -u cloudflared-argo | grep trycloudflare${NC}"
    echo "https://trycloudflare.com-placeholder" > "$ARGO_DOMAIN_FILE"
  fi

  show_nodes
}

### 修改配置
modify_config() {
  [ -f "$SB_CONFIG" ] || { echo -e "${RED}未检测到配置文件，请先安装${NC}"; return; }

  HY_CUR=$(jq '.inbounds[]|select(.tag=="hy2")|.listen_port' $SB_CONFIG)
  VL_CUR=$(jq '.inbounds[]|select(.tag=="reality")|.listen_port' $SB_CONFIG)
  DOMAIN_CUR=$(jq -r '.inbounds[]|select(.tag=="reality")|.tls.server_name' $SB_CONFIG)
  PASS_CUR=$(jq -r '.inbounds[]|select(.tag=="hy2")|.users[0].password' $SB_CONFIG)
  UUID_CUR=$(jq -r '.inbounds[]|select(.tag=="reality")|.users[0].uuid' $SB_CONFIG)
  SID_CUR=$(jq -r '.inbounds[]|select(.tag=="reality")|.tls.reality.short_id[0]' $SB_CONFIG)

  WS_LOCAL_CUR=$(jq '.inbounds[]|select(.tag=="vless-ws-argo")|.listen_port' $SB_CONFIG)
  WS_PATH_CUR=$(jq -r '.inbounds[]|select(.tag=="vless-ws-argo")|.transport.path' $SB_CONFIG)

  [ -f "$KEY_FILE" ] || gen_reality_key
  PRIV_KEY=$(awk '/PrivateKey/ {print $2}' "$KEY_FILE")

  echo
  echo -e "${GREEN}当前配置:${NC}"
  echo "Hysteria2 端口: $HY_CUR"
  echo "VLESS Reality 端口: $VL_CUR"
  echo "Reality 伪装域名: $DOMAIN_CUR"
  echo
  echo -e "${GREEN}Argo WS 节点 (Quick Tunnel):${NC}"
  echo "本地监听端口: $WS_LOCAL_CUR"
  echo "WebSocket 路径: $WS_PATH_CUR"
  echo "自定义节点名称: $CUSTOM_NAME"
  if [ -f "$ARGO_DOMAIN_FILE" ]; then
    echo "当前 Argo 域名: $(cat $ARGO_DOMAIN_FILE)"
  fi
  echo

  read -p "是否直接使用编辑器 (nano) 修改配置文件? [y/N]: " use_editor
  if [[ "$use_editor" =~ ^[Yy]$ ]]; then
    ${EDITOR:-nano} "$SB_CONFIG"
    systemctl restart sing-box
    echo -e "${GREEN}配置已保存并重启服务${NC}"
    show_nodes
    return
  fi

  read -p "Hysteria2 端口 [默认 $HY_CUR]: " NEW_HY
  read -p "VLESS Reality 端口 [默认 $VL_CUR]: " NEW_VL
  read -p "Reality 伪装域名 [默认 $DOMAIN_CUR]: " NEW_DOMAIN
  read -p "自定义节点名称 [默认 $CUSTOM_NAME]: " NEW_NAME
  read -p "WS 本地端口 (Argo) [默认 $WS_LOCAL_CUR]: " NEW_WS_LOCAL
  read -p "WebSocket 路径 [默认 $WS_PATH_CUR]: " NEW_WS_PATH

  NEW_HY=${NEW_HY:-$HY_CUR}
  NEW_VL=${NEW_VL:-$VL_CUR}
  NEW_DOMAIN=${NEW_DOMAIN:-$DOMAIN_CUR}
  NEW_NAME=${NEW_NAME:-$CUSTOM_NAME}
  NEW_WS_LOCAL=${NEW_WS_LOCAL:-$WS_LOCAL_CUR}
  NEW_WS_PATH=${NEW_WS_PATH:-$WS_PATH_CUR}

  CUSTOM_NAME=$NEW_NAME

  if [ "$NEW_HY" != "$HY_CUR" ]; then
    check_port $NEW_HY || { echo -e "${RED}端口 $NEW_HY 被占用${NC}"; return; }
  fi
  if [ "$NEW_VL" != "$VL_CUR" ]; then
    check_port $NEW_VL || { echo -e "${RED}端口 $NEW_VL 被占用${NC}"; return; }
  fi

cat > "$SB_CONFIG" <<EOF
{
  "log": { "level": "info" },
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "hy2",
      "listen": "::",
      "listen_port": $NEW_HY,
      "users": [{ "password": "$PASS_CUR" }],
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
      "listen_port": $NEW_VL,
      "users": [{
        "uuid": "$UUID_CUR",
        "flow": "xtls-rprx-vision"
      }],
      "tls": {
        "enabled": true,
        "server_name": "$NEW_DOMAIN",
        "reality": {
          "enabled": true,
          "handshake": { "server": "$NEW_DOMAIN", "server_port": 443 },
          "private_key": "$PRIV_KEY",
          "short_id": ["$SID_CUR"]
        }
      }
    },
    {
      "type": "vless",
      "tag": "vless-ws-argo",
      "listen": "127.0.0.1",
      "listen_port": $NEW_WS_LOCAL,
      "users": [{
        "uuid": "$UUID_CUR"
      }],
      "transport": {
        "type": "ws",
        "path": "$NEW_WS_PATH"
      }
    }
  ],
  "outbounds": [{ "type": "direct" }]
}
EOF

  systemctl restart sing-box

  # 重启 Argo Tunnel
  if systemctl is-active cloudflared-argo >/dev/null 2>&1; then
    systemctl restart cloudflared-argo
    sleep 8
    ARGO_URL=$(journalctl -u cloudflared-argo --since "2 min ago" --no-pager | grep -o 'https://[^ ]*\.trycloudflare\.com' | tail -1)
    if [ -n "$ARGO_URL" ]; then
      echo "$ARGO_URL" > "$ARGO_DOMAIN_FILE"
    fi
  fi

  echo -e "${GREEN}配置已更新并重启服务${NC}"
  show_nodes
}

### 输出节点
show_nodes() {
  [ ! -f "$SB_CONFIG" ] && { echo -e "${RED}配置文件不存在，请先安装${NC}"; return; }

  IP=$(curl -s ipv4.ip.sb 2>/dev/null || echo "YOUR_IP")
  HY_PORT=$(jq '.inbounds[]|select(.tag=="hy2")|.listen_port' $SB_CONFIG 2>/dev/null)
  VL_PORT=$(jq '.inbounds[]|select(.tag=="reality")|.listen_port' $SB_CONFIG 2>/dev/null)
  PASS=$(jq -r '.inbounds[]|select(.tag=="hy2")|.users[0].password' $SB_CONFIG 2>/dev/null)
  UUID=$(jq -r '.inbounds[]|select(.tag=="reality")|.users[0].uuid' $SB_CONFIG 2>/dev/null)
  DOMAIN=$(jq -r '.inbounds[]|select(.tag=="reality")|.tls.server_name' $SB_CONFIG 2>/dev/null)
  SID=$(jq -r '.inbounds[]|select(.tag=="reality")|.tls.reality.short_id[0]' $SB_CONFIG 2>/dev/null)
  PUB_KEY="$FIXED_REALITY_PUBKEY"

  WS_LOCAL=$(jq '.inbounds[]|select(.tag=="vless-ws-argo")|.listen_port' $SB_CONFIG 2>/dev/null)
  WS_PATH=$(jq -r '.inbounds[]|select(.tag=="vless-ws-argo")|.transport.path' $SB_CONFIG 2>/dev/null)

  # Argo 域名
  ARGO_DOMAIN=""
  if [ -f "$ARGO_DOMAIN_FILE" ]; then
    ARGO_FULL=$(cat "$ARGO_DOMAIN_FILE")
    ARGO_DOMAIN=$(echo "$ARGO_FULL" | sed 's|https://||')
  fi

  # 证书指纹（仅 Hysteria2）
  FINGERPRINT=""
  if command -v openssl >/dev/null 2>&1 && [ -f "$CERT_DIR/server.crt" ]; then
    FINGERPRINT=$(openssl x509 -in "$CERT_DIR/server.crt" -noout -fingerprint -sha256 2>/dev/null | \
      cut -d= -f2 | tr -d ':' | tr '[:upper:]' '[:lower:]' || true)
    if [ ${#FINGERPRINT} -ne 64 ] || ! [[ "$FINGERPRINT" =~ ^[0-9a-f]+$ ]]; then
      FINGERPRINT=""
    fi
  fi

  echo
  echo -e "${GREEN}===== 节点配置已生成 (Argo Quick Tunnel 版) =====${NC}"
  echo

  echo -e "Hysteria2 (高速模式):"
  if [ -n "$FINGERPRINT" ]; then
    echo "hy2://$PASS@$IP:$HY_PORT/?pinSHA256=$FINGERPRINT&alpn=h3#$CUSTOM_NAME-Hy2"
  else
    echo "hy2://$PASS@$IP:$HY_PORT/?insecure=1&alpn=h3#$CUSTOM_NAME-Hy2"
  fi
  echo

  echo -e "VLESS Reality (稳健模式):"
  echo "vless://$UUID@$IP:$VL_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$DOMAIN&fp=chrome&pbk=$PUB_KEY&sid=$SID&type=tcp#$CUSTOM_NAME-Reality"
  echo

  if [ -n "$ARGO_DOMAIN" ] && [ "$ARGO_DOMAIN" != "https://trycloudflare.com-placeholder" ]; then
    echo -e "VLESS WS + Argo Quick Tunnel (零端口 + Cloudflare 防护):"
    echo "vless://$UUID@$ARGO_DOMAIN:443?encryption=none&security=tls&type=ws&host=$ARGO_DOMAIN&path=$WS_PATH#$CUSTOM_NAME-CDN"
    echo
    echo -e "${YELLOW}【使用说明】${NC}"
    echo "• 该节点完全不暴露服务器端口，由 Cloudflare Quick Tunnel 提供"
    echo "• Quick Tunnel 域名是临时的，重启服务器后可能变化"
    echo "• 如需固定域名，建议改用 Named Tunnel（需 Cloudflare Token）"
    echo "• 客户端可直接使用以上链接"
  else
    echo -e "${YELLOW}Argo Tunnel 域名获取失败，请手动查看: journalctl -u cloudflared-argo${NC}"
  fi

  if [ -n "$FINGERPRINT" ]; then
    echo -e "${GREEN}Hysteria2 已启用 pinSHA256 证书固定${NC}"
  fi
  echo
}

### 菜单
menu() {
  while true; do
    clear
    echo "========== sing-box + Argo Quick Tunnel 管理面板 =========="
    echo "1. 安装 / 重新安装（Hysteria2 + Reality + Argo WS）"
    echo "2. 查看节点信息"
    echo "3. 运行状态"
    echo "4. 实时日志"
    echo "5. 重启服务"
    echo "6. 彻底卸载"
    echo "7. 修改配置"
    echo "0. 退出"
    read -p "请选择 [0-7]: " num
    case $num in
      1) install_deps; install_singbox; enable_bbr; install_all ;;
      2) [ -f "$SB_CONFIG" ] && show_nodes || echo "请先安装" ;;
      3) 
        echo "=== sing-box ==="; systemctl status sing-box --no-pager
        echo "=== cloudflared-argo ==="; systemctl status cloudflared-argo --no-pager
        ;;
      4) 
        echo "按 Ctrl+C 退出日志"
        journalctl -u sing-box -u cloudflared-argo -f 
        ;;
      5) 
        systemctl restart sing-box
        systemctl restart cloudflared-argo
        echo "已重启"
        ;;
      6) 
        systemctl stop sing-box cloudflared-argo 2>/dev/null
        rm -rf "$SB_DIR" "$SERVICE_FILE" "$ARGO_SERVICE" /usr/local/bin/cloudflared 2>/dev/null
        systemctl daemon-reload
        echo "已彻底卸载"
        ;;
      7) modify_config ;;
      0) exit ;;
      *) echo "无效选择" ;;
    esac
   
    [ "$num" != "0" ] && read -p "按 Enter 继续..." && continue
  done
}

check_root
menu
