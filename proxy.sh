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

### 全局变量（用于记录已启用协议）
ENABLE_HY2=false
ENABLE_REALITY=false
ENABLE_ARGO=false

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
  if command -v cloudflared >/dev/null; then return; fi
  echo -e "${GREEN}正在安装 cloudflared (Argo Tunnel)...${NC}"
  ARCH=$(uname -m)
  if [ "$ARCH" = "x86_64" ]; then
    CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
  elif [ "$ARCH" = "aarch64" ]; then
    CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"
  else
    echo -e "${RED}不支持的架构: $ARCH${NC}" && exit 1
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

### 生成自签证书（Hysteria2 使用）
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

### 安装配置（支持可选协议）
install_all() {
  echo -e "\n${GREEN}===== 协议选择 =====${NC}"
  read -p "是否安装 Hysteria2? (y/n) [默认 y]: " hy_choice
  read -p "是否安装 VLESS Reality? (y/n) [默认 y]: " reality_choice
  read -p "是否安装 VLESS WS + Argo Quick Tunnel? (y/n) [默认 y]: " argo_choice

  ENABLE_HY2=${hy_choice:-y}
  ENABLE_REALITY=${reality_choice:-y}
  ENABLE_ARGO=${argo_choice:-y}

  [[ "$ENABLE_HY2" =~ ^[Yy]$ ]] && ENABLE_HY2=true || ENABLE_HY2=false
  [[ "$ENABLE_REALITY" =~ ^[Yy]$ ]] && ENABLE_REALITY=true || ENABLE_REALITY=false
  [[ "$ENABLE_ARGO" =~ ^[Yy]$ ]] && ENABLE_ARGO=true || ENABLE_ARGO=false

  if ! $ENABLE_HY2 && ! $ENABLE_REALITY && ! $ENABLE_ARGO; then
    echo -e "${RED}必须至少选择一个协议${NC}" && return
  fi

  # 端口与域名配置
  if $ENABLE_HY2; then
    read -p "Hysteria2 端口 [默认 443]: " HY_PORT
    HY_PORT=${HY_PORT:-443}
    check_port $HY_PORT || { echo -e "${RED}端口 $HY_PORT 被占用${NC}"; return; }
  fi

  if $ENABLE_REALITY; then
    read -p "VLESS Reality 端口 [默认 8443]: " VL_PORT
    VL_PORT=${VL_PORT:-8443}
    check_port $VL_PORT || { echo -e "${RED}端口 $VL_PORT 被占用${NC}"; return; }
  fi

  read -p "自定义节点名称 [默认 SingBox]: " INPUT_NAME
  CUSTOM_NAME=${INPUT_NAME:-SingBox}

  if $ENABLE_REALITY; then
    echo -e "\n${GREEN}设置 Reality 伪装域名 (SNI):${NC}"
    read -p "请输入域名 (直接回车默认 www.microsoft.com): " INPUT_DOMAIN
    DOMAIN=${INPUT_DOMAIN:-www.microsoft.com}
  fi

  # Argo 配置
  if $ENABLE_ARGO; then
    echo -e "\n${GREEN}===== Argo Quick Tunnel 配置 =====${NC}"
    read -p "WS 本地监听端口 [默认 $DEFAULT_WS_LOCAL_PORT]: " WS_LOCAL_PORT
    read -p "WebSocket 路径 [默认 $DEFAULT_WS_PATH]: " WS_PATH
    WS_LOCAL_PORT=${WS_LOCAL_PORT:-$DEFAULT_WS_LOCAL_PORT}
    WS_PATH=${WS_PATH:-$DEFAULT_WS_PATH}
  fi

  UUID="$FIXED_VLESS_UUID"
  PASS="$FIXED_HY2_PASS"
  SID="$FIXED_REALITY_SHORTID"

  gen_cert
  gen_reality_key
  PRIV_KEY="$FIXED_REALITY_PRIVKEY"
  mkdir -p "$SB_DIR"

  # 动态生成 inbounds
  INBOUNDS="["

  if $ENABLE_HY2; then
    INBOUNDS+='
    {
      "type": "hysteria2",
      "tag": "hy2",
      "listen": "::",
      "listen_port": '"$HY_PORT"',
      "users": [{ "password": "'"$PASS"'" }],
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "'"$CERT_DIR/server.crt"'",
        "key_path": "'"$CERT_DIR/server.key"'"
      }
    },'
  fi

  if $ENABLE_REALITY; then
    INBOUNDS+='
    {
      "type": "vless",
      "tag": "reality",
      "listen": "::",
      "listen_port": '"$VL_PORT"',
      "users": [{ "uuid": "'"$UUID"'", "flow": "xtls-rprx-vision" }],
      "tls": {
        "enabled": true,
        "server_name": "'"$DOMAIN"'",
        "reality": {
          "enabled": true,
          "handshake": { "server": "'"$DOMAIN"'", "server_port": 443 },
          "private_key": "'"$PRIV_KEY"'",
          "short_id": ["'"$SID"'"]
        }
      }
    },'
  fi

  if $ENABLE_ARGO; then
    INBOUNDS+='
    {
      "type": "vless",
      "tag": "vless-ws-argo",
      "listen": "127.0.0.1",
      "listen_port": '"$WS_LOCAL_PORT"',
      "users": [{ "uuid": "'"$UUID"'" }],
      "transport": {
        "type": "ws",
        "path": "'"$WS_PATH"'"
      }
    }'
  fi

  INBOUNDS="${INBOUNDS%,}]"  # 去除最后一个逗号

cat > "$SB_CONFIG" <<EOF
{
  "log": { "level": "info" },
  "inbounds": $INBOUNDS,
  "outbounds": [{ "type": "direct" }]
}
EOF

  # 创建 systemd 服务
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
  systemctl enable --now sing-box

  # Argo 服务
  if $ENABLE_ARGO; then
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
    systemctl enable --now cloudflared-argo

    sleep 10
    ARGO_URL=$(journalctl -u cloudflared-argo --since "2 min ago" --no-pager | grep -o 'https://[^ ]*\.trycloudflare\.com' | tail -1)
    if [ -n "$ARGO_URL" ]; then
      echo "$ARGO_URL" > "$ARGO_DOMAIN_FILE"
    else
      echo "https://trycloudflare.com-placeholder" > "$ARGO_DOMAIN_FILE"
    fi
  fi

  echo -e "${GREEN}安装完成！${NC}"
  show_nodes
}

### 修改配置（支持可选协议）
modify_config() {
  [ -f "$SB_CONFIG" ] || { echo -e "${RED}未检测到配置文件${NC}"; return; }

  # 检测当前已启用协议（简化处理）
  jq -e '.inbounds[] | select(.tag=="hy2")' "$SB_CONFIG" >/dev/null && ENABLE_HY2=true || ENABLE_HY2=false
  jq -e '.inbounds[] | select(.tag=="reality")' "$SB_CONFIG" >/dev/null && ENABLE_REALITY=true || ENABLE_REALITY=false
  jq -e '.inbounds[] | select(.tag=="vless-ws-argo")' "$SB_CONFIG" >/dev/null && ENABLE_ARGO=true || ENABLE_ARGO=false

  # ...（后续可继续扩展交互式修改，此处保持原有核心逻辑）
  echo -e "${YELLOW}当前已启用协议: ${NC}"
  $ENABLE_HY2 && echo "• Hysteria2"
  $ENABLE_REALITY && echo "• VLESS Reality"
  $ENABLE_ARGO && echo "• VLESS WS + Argo"

  read -p "是否直接使用 nano 编辑配置文件? [y/N]: " use_editor
  if [[ "$use_editor" =~ ^[Yy]$ ]]; then
    ${EDITOR:-nano} "$SB_CONFIG"
    systemctl restart sing-box
    if $ENABLE_ARGO; then systemctl restart cloudflared-argo; fi
    echo -e "${GREEN}配置已更新${NC}"
  else
    echo -e "${YELLOW}完整交互修改暂未实现，推荐使用 nano 直接编辑${NC}"
  fi
  show_nodes
}

### 输出节点（仅显示已启用协议）
show_nodes() {
  [ ! -f "$SB_CONFIG" ] && { echo -e "${RED}配置文件不存在${NC}"; return; }

  IP=$(curl -s ipv4.ip.sb 2>/dev/null || echo "YOUR_IP")
  CUSTOM_NAME=$(jq -r '.inbounds[0].tag' "$SB_CONFIG" 2>/dev/null || echo "SingBox") # 简化

  echo -e "\n${GREEN}===== 当前可用节点 =====${NC}\n"

  if $ENABLE_HY2 || jq -e '.inbounds[] | select(.tag=="hy2")' "$SB_CONFIG" >/dev/null; then
    echo -e "${GREEN}Hysteria2:${NC}"
    PASS=$(jq -r '.inbounds[]|select(.tag=="hy2")|.users[0].password' "$SB_CONFIG")
    HY_PORT=$(jq '.inbounds[]|select(.tag=="hy2")|.listen_port' "$SB_CONFIG")
    echo "hy2://$PASS@$IP:$HY_PORT/?alpn=h3#$CUSTOM_NAME-Hy2"
    echo
  fi

  if $ENABLE_REALITY || jq -e '.inbounds[] | select(.tag=="reality")' "$SB_CONFIG" >/dev/null; then
    echo -e "${GREEN}VLESS Reality:${NC}"
    UUID=$(jq -r '.inbounds[]|select(.tag=="reality")|.users[0].uuid' "$SB_CONFIG")
    VL_PORT=$(jq '.inbounds[]|select(.tag=="reality")|.listen_port' "$SB_CONFIG")
    DOMAIN=$(jq -r '.inbounds[]|select(.tag=="reality")|.tls.server_name' "$SB_CONFIG")
    echo "vless://$UUID@$IP:$VL_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$DOMAIN&fp=chrome&pbk=$FIXED_REALITY_PUBKEY&sid=$FIXED_REALITY_SHORTID&type=tcp#$CUSTOM_NAME-Reality"
    echo
  fi

  if $ENABLE_ARGO || jq -e '.inbounds[] | select(.tag=="vless-ws-argo")' "$SB_CONFIG" >/dev/null; then
    ARGO_DOMAIN=$(cat "$ARGO_DOMAIN_FILE" 2>/dev/null | sed 's|https://||')
    if [ -n "$ARGO_DOMAIN" ] && [ "$ARGO_DOMAIN" != "trycloudflare.com-placeholder" ]; then
      echo -e "${GREEN}VLESS WS + Argo Quick Tunnel:${NC}"
      WS_PATH=$(jq -r '.inbounds[]|select(.tag=="vless-ws-argo")|.transport.path' "$SB_CONFIG")
      echo "vless://$UUID@$ARGO_DOMAIN:443?encryption=none&security=tls&type=ws&host=$ARGO_DOMAIN&path=$WS_PATH#$CUSTOM_NAME-CDN"
      echo -e "${YELLOW}提示：Quick Tunnel 域名重启后可能变化${NC}\n"
    fi
  fi
}

### 菜单
menu() {
  while true; do
    clear
    echo "========== sing-box 可选协议管理面板 =========="
    echo "1. 安装 / 重新安装（可选协议）"
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
      2) show_nodes ;;
      3)
        echo "=== sing-box ==="; systemctl status sing-box --no-pager
        echo "=== cloudflared-argo ==="; systemctl status cloudflared-argo --no-pager 2>/dev/null || echo "Argo 未启用"
        ;;
      4)
        echo "按 Ctrl+C 退出日志"
        journalctl -u sing-box -u cloudflared-argo -f 2>/dev/null
        ;;
      5)
        systemctl restart sing-box
        systemctl restart cloudflared-argo 2>/dev/null
        echo "服务已重启"
        ;;
      6)
        systemctl stop sing-box cloudflared-argo 2>/dev/null
        rm -rf "$SB_DIR" "$SERVICE_FILE" "$ARGO_SERVICE" /usr/local/bin/cloudflared 2>/dev/null
        systemctl daemon-reload
        echo "已彻底卸载"
        ;;
      7) modify_config ;;
      0) exit 0 ;;
      *) echo "无效选择" ;;
    esac
    [ "$num" != "0" ] && read -p "按 Enter 继续..." 
  done
}

check_root
menu
