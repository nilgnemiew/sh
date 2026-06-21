#!/bin/bash
### 基础路径
XB_DIR="/etc/xray"
CERT_DIR="$XB_DIR/cert"
XB_CONFIG="$XB_DIR/config.json"
KEY_FILE="$XB_DIR/reality.key"
SERVICE_FILE="/etc/systemd/system/xray.service"
ARGO_SERVICE="/etc/systemd/system/cloudflared-argo.service"
ARGO_DOMAIN_FILE="$XB_DIR/argo_domain.txt"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'
CUSTOM_NAME="Xray"

### 固定配置值
FIXED_VLESS_UUID="93be88a8-1880-4359-90af-fd2d266a9863"
FIXED_REALITY_SHORTID="b631f62d"
FIXED_REALITY_PUBKEY="y4_s_qNaoQdxwD91KAZOHlpLcJpaSy0RBVflQv4-Zlw"
FIXED_REALITY_PRIVKEY="SNpaGKzmrS131QIPhl92ato75liiD2_a12EomxDBz3U"

### 默认值
DEFAULT_REALITY_PORT=443
DEFAULT_WS_LOCAL_PORT=8080
DEFAULT_WS_PATH="/ws"

ENABLE_REALITY=false
ENABLE_ARGO=false

check_root() {
  [ "$EUID" -ne 0 ] && echo -e "${RED}请使用 root 执行${NC}" && exit 1
}

install_deps() {
  echo -e "${GREEN}正在安装依赖...${NC}"
  command -v jq >/dev/null || (apt update && apt install -y jq || yum install -y jq)
  command -v curl >/dev/null || (apt update && apt install -y curl || yum install -y curl)
  command -v openssl >/dev/null || (apt update && apt install -y openssl || yum install -y openssl)
}

install_xray() {
  if command -v xray >/dev/null; then
    echo -e "${GREEN}Xray 已安装${NC}"
    return
  fi
  echo -e "${GREEN}正在安装 Xray...${NC}"
  bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
}

gen_cert() {
  mkdir -p "$CERT_DIR"
  if [ ! -f "$CERT_DIR/server.key" ]; then
    echo -e "${GREEN}生成自签证书...${NC}"
    openssl req -x509 -nodes -newkey rsa:2048 \
      -keyout "$CERT_DIR/server.key" \
      -out "$CERT_DIR/server.crt" \
      -days 3650 \
      -subj "/C=US/O=Xray/CN=Xray"
  fi
}

gen_reality_key() {
  mkdir -p "$XB_DIR"
  if [ ! -f "$KEY_FILE" ]; then
    echo -e "${GREEN}写入固定 Reality 密钥对...${NC}"
    cat > "$KEY_FILE" <<EOF
PrivateKey: $FIXED_REALITY_PRIVKEY
PublicKey: $FIXED_REALITY_PUBKEY
EOF
    chmod 600 "$KEY_FILE"
  fi
}

check_port() {
  ss -lntup | grep -q ":$1 " && return 1 || return 0
}

install_all() {
  echo -e "\n${GREEN}===== 协议选择 =====${NC}"
  read -p "是否安装 VLESS Reality? (y/n) [默认 y]: " reality_choice
  read -p "是否安装 VLESS WS + Argo Quick Tunnel? (y/n) [默认 y]: " argo_choice

  ENABLE_REALITY=${reality_choice:-y}
  ENABLE_ARGO=${argo_choice:-y}
  [[ "$ENABLE_REALITY" =~ ^[Yy]$ ]] && ENABLE_REALITY=true || ENABLE_REALITY=false
  [[ "$ENABLE_ARGO" =~ ^[Yy]$ ]] && ENABLE_ARGO=true || ENABLE_ARGO=false

  if ! $ENABLE_REALITY && ! $ENABLE_ARGO; then
    echo -e "${RED}必须至少选择一个协议${NC}" && return 1
  fi

  # Reality 配置（默认443）
  if $ENABLE_REALITY; then
    read -p "VLESS Reality 端口 [默认 $DEFAULT_REALITY_PORT]: " VL_PORT
    VL_PORT=${VL_PORT:-$DEFAULT_REALITY_PORT}
    check_port $VL_PORT || { echo -e "${RED}端口 $VL_PORT 被占用${NC}"; return 1; }

    echo -e "\n${GREEN}设置 Reality 伪装域名 (SNI):${NC}"
    read -p "请输入域名 (直接回车默认 www.bing.com): " INPUT_DOMAIN
    DOMAIN=${INPUT_DOMAIN:-www.bing.com}
  fi

  # Argo 配置
  if $ENABLE_ARGO; then
    read -p "WS 本地监听端口 [默认 $DEFAULT_WS_LOCAL_PORT]: " WS_LOCAL_PORT
    read -p "WebSocket 路径 [默认 $DEFAULT_WS_PATH]: " WS_PATH
    WS_LOCAL_PORT=${WS_LOCAL_PORT:-$DEFAULT_WS_LOCAL_PORT}
    WS_PATH=${WS_PATH:-$DEFAULT_WS_PATH}
  fi

  read -p "自定义节点名称 [默认 Xray]: " INPUT_NAME
  CUSTOM_NAME=${INPUT_NAME:-Xray}

  mkdir -p "$XB_DIR" "$CERT_DIR"
  gen_cert
  gen_reality_key

  # 生成 inbounds
  INBOUNDS="["
  if $ENABLE_REALITY; then
    INBOUNDS+='
    {
      "tag": "reality",
      "listen": "::",
      "port": '"$VL_PORT"',
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "'"$FIXED_VLESS_UUID"'", "flow": "xtls-rprx-vision"}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "'"$DOMAIN"':443",
          "xver": 0,
          "serverNames": ["'"$DOMAIN"'"],
          "privateKey": "'"$FIXED_REALITY_PRIVKEY"'",
          "shortIds": ["'"$FIXED_REALITY_SHORTID"'"]
        }
      }
    }'
  fi

  if $ENABLE_ARGO; then
    [ "$ENABLE_REALITY" = true ] && INBOUNDS+=","
    INBOUNDS+='
    {
      "tag": "vless-ws-argo",
      "listen": "127.0.0.1",
      "port": '"$WS_LOCAL_PORT"',
      "protocol": "vless",
      "settings": {"clients": [{"id": "'"$FIXED_VLESS_UUID"'"}]},
      "streamSettings": {
        "network": "ws",
        "wsSettings": {"path": "'"$WS_PATH"'"}
      }
    }'
  fi
  INBOUNDS="${INBOUNDS}]"

  cat > "$XB_CONFIG" <<EOF
{
  "log": {"loglevel": "info"},
  "inbounds": $INBOUNDS,
  "outbounds": [{"tag": "direct", "protocol": "freedom"}]
}
EOF

  # systemd 服务
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Xray Service
After=network.target
[Service]
ExecStart=/usr/local/bin/xray run -c $XB_CONFIG
Restart=on-failure
LimitNOFILE=51200
[Install]
WantedBy=multi-user.target
EOF

  # 清理可能存在的官方安装脚本生成的冲突配置
  rm -rf /etc/systemd/system/xray.service.d
  systemctl daemon-reload
  systemctl enable --now xray

  # Argo 服务
  if $ENABLE_ARGO; then
    if ! command -v cloudflared >/dev/null; then
      echo -e "${GREEN}正在安装 cloudflared...${NC}"
      ARCH=$(uname -m)
      if [ "$ARCH" = "x86_64" ]; then
        CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
      elif [ "$ARCH" = "aarch64" ]; then
        CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"
      else
        echo -e "${RED}不支持的架构${NC}" && return 1
      fi
      wget -q "$CF_URL" -O /usr/local/bin/cloudflared && chmod +x /usr/local/bin/cloudflared
    fi

    cat > "$ARGO_SERVICE" <<EOF
[Unit]
Description=Cloudflare Quick Tunnel for Xray WS
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

    # 获取 Argo 域名
    for i in {1..5}; do
      ARGO_URL=$(journalctl -u cloudflared-argo --since "30 sec ago" --no-pager | grep -o 'https://[^ ]*\.trycloudflare\.com' | tail -1)
      [ -n "$ARGO_URL" ] && break
      sleep 3
    done
    if [ -n "$ARGO_URL" ]; then
      echo "$ARGO_URL" > "$ARGO_DOMAIN_FILE"
    else
      echo "https://trycloudflare.com-placeholder" > "$ARGO_DOMAIN_FILE"
    fi
  fi

  echo -e "${GREEN}✅ Xray 安装完成！${NC}"
  show_nodes
}

modify_config() {
  [ -f "$XB_CONFIG" ] || { echo -e "${RED}配置文件不存在${NC}"; return; }
  echo -e "${YELLOW}推荐直接使用 nano 编辑配置文件${NC}"
  read -p "是否打开 nano 编辑? (y/N): " use_editor
  if [[ "$use_editor" =~ ^[Yy]$ ]]; then
    ${EDITOR:-nano} "$XB_CONFIG"
    systemctl restart xray
    [ -f "$ARGO_SERVICE" ] && systemctl restart cloudflared-argo
    echo -e "${GREEN}配置已更新并重启${NC}"
  fi
  show_nodes
}

show_nodes() {
  [ ! -f "$XB_CONFIG" ] && { echo -e "${RED}配置文件不存在${NC}"; return; }
  IP=$(curl -s ipv4.ip.sb 2>/dev/null || echo "YOUR_IP")
  echo -e "\n${GREEN}===== 当前可用节点 =====${NC}\n"

  if jq -e '.inbounds[] | select(.tag=="reality")' "$XB_CONFIG" >/dev/null 2>&1; then
    echo -e "${GREEN}VLESS Reality:${NC}"
    VL_PORT=$(jq '.inbounds[]|select(.tag=="reality")|.port' "$XB_CONFIG")
    DOMAIN=$(jq -r '.inbounds[]|select(.tag=="reality")|.streamSettings.realitySettings.dest' "$XB_CONFIG" | cut -d: -f1)
    echo "vless://$FIXED_VLESS_UUID@$IP:$VL_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$DOMAIN&fp=chrome&pbk=$FIXED_REALITY_PUBKEY&sid=$FIXED_REALITY_SHORTID&type=tcp#$CUSTOM_NAME-Reality"
    echo
  fi

  if jq -e '.inbounds[] | select(.tag=="vless-ws-argo")' "$XB_CONFIG" >/dev/null 2>&1; then
    ARGO_DOMAIN=$(cat "$ARGO_DOMAIN_FILE" 2>/dev/null | sed 's|https://||')
    if [ -n "$ARGO_DOMAIN" ] && [ "$ARGO_DOMAIN" != "trycloudflare.com-placeholder" ]; then
      echo -e "${GREEN}VLESS WS + Argo Quick Tunnel:${NC}"
      WS_PATH=$(jq -r '.inbounds[]|select(.tag=="vless-ws-argo")|.streamSettings.wsSettings.path' "$XB_CONFIG")
      echo "vless://$FIXED_VLESS_UUID@$ARGO_DOMAIN:443?encryption=none&security=tls&type=ws&host=$ARGO_DOMAIN&path=$WS_PATH#$CUSTOM_NAME-CDN"
      echo -e "${YELLOW}提示：Argo 域名重启后可能变化，可通过 journalctl -u cloudflared-argo 查看最新域名${NC}\n"
    fi
  fi
}

menu() {
  while true; do
    clear
    echo "========== Xray 管理面板 (Reality 默认443 | 无防火墙) =========="
    echo "1. 安装 / 重新安装"
    echo "2. 查看节点信息"
    echo "3. 运行状态"
    echo "4. 实时日志"
    echo "5. 重启服务"
    echo "6. 彻底卸载"
    echo "7. 修改配置"
    echo "0. 退出"
    read -p "请选择 [0-7]: " num
    case $num in
      1) install_deps; install_xray; install_all ;;
      2) show_nodes ;;
      3)
        echo "=== Xray ==="; systemctl status xray --no-pager
        echo "=== cloudflared ==="; systemctl status cloudflared-argo --no-pager 2>/dev/null || echo "Argo 未启用"
        ;;
      4) journalctl -u xray -u cloudflared-argo -f ;;
      5)
        systemctl restart xray
        systemctl restart cloudflared-argo 2>/dev/null
        echo -e "${GREEN}服务已重启${NC}"
        ;;
      6)
        systemctl stop xray cloudflared-argo 2>/dev/null
        rm -rf "$XB_DIR" "$SERVICE_FILE" "$ARGO_SERVICE" /usr/local/bin/cloudflared 2>/dev/null
        systemctl daemon-reload
        echo -e "${GREEN}已彻底卸载${NC}"
        ;;
      7) modify_config ;;
      0) exit 0 ;;
      *) echo -e "${RED}无效选择${NC}" ;;
    esac
    [ "$num" != "0" ] && read -p "按 Enter 继续..."
  done
}

check_root
menu
