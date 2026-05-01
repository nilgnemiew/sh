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

CUSTOM_NAME="SingBox"

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
  read -p "自定义节点名称 [默认 SingBox]: " INPUT_NAME

  HY_PORT=${HY_PORT:-443}
  VL_PORT=${VL_PORT:-8443}
  CUSTOM_NAME=${INPUT_NAME:-SingBox}

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

### 修改配置（新增）
modify_config() {
  [ -f "$SB_CONFIG" ] || { echo -e "${RED}未检测到配置文件，请先安装${NC}"; return; }

  # 读取当前配置
  HY_CUR=$(jq '.inbounds[]|select(.tag=="hy2")|.listen_port' $SB_CONFIG)
  VL_CUR=$(jq '.inbounds[]|select(.tag=="reality")|.listen_port' $SB_CONFIG)
  DOMAIN_CUR=$(jq -r '.inbounds[]|select(.tag=="reality")|.tls.server_name' $SB_CONFIG)
  PASS_CUR=$(jq -r '.inbounds[]|select(.tag=="hy2")|.users[0].password' $SB_CONFIG)
  UUID_CUR=$(jq -r '.inbounds[]|select(.tag=="reality")|.users[0].uuid' $SB_CONFIG)
  SID_CUR=$(jq -r '.inbounds[]|select(.tag=="reality")|.tls.reality.short_id[0]' $SB_CONFIG)
  [ -f "$KEY_FILE" ] || gen_reality_key
  PRIV_KEY=$(awk '/PrivateKey/ {print $2}' "$KEY_FILE")

  echo
  echo -e "${GREEN}当前配置:${NC}"
  echo "Hysteria2 端口: $HY_CUR"
  echo "VLESS Reality 端口: $VL_CUR"
  echo "Reality 伪装域名 (SNI): $DOMAIN_CUR"
  echo "Hysteria2 密码: $PASS_CUR"
  echo "VLESS UUID: $UUID_CUR"
  echo "自定义节点名称: $CUSTOM_NAME"
  echo

  read -p "是否直接使用编辑器 (nano) 修改配置文件? [y/N]: " use_editor
  if [[ "$use_editor" =~ ^[Yy]$ ]]; then
    ${EDITOR:-nano} "$SB_CONFIG"
    systemctl restart sing-box
    echo -e "${GREEN}配置已保存并重启服务${NC}"
    show_nodes
    return
  fi

  # 交互式修改（保留关键字段）
  read -p "Hysteria2 端口 [默认 $HY_CUR]: " NEW_HY
  read -p "VLESS Reality 端口 [默认 $VL_CUR]: " NEW_VL
  read -p "Reality 伪装域名 (SNI) [默认 $DOMAIN_CUR]: " NEW_DOMAIN
  read -p "自定义节点名称 [默认 $CUSTOM_NAME]: " NEW_NAME

  NEW_HY=${NEW_HY:-$HY_CUR}
  NEW_VL=${NEW_VL:-$VL_CUR}
  NEW_DOMAIN=${NEW_DOMAIN:-$DOMAIN_CUR}
  NEW_NAME=${NEW_NAME:-$CUSTOM_NAME}
  CUSTOM_NAME=$NEW_NAME

  # 如果更改端口，则检查端口占用（允许当前端口）
  if [ "$NEW_HY" != "$HY_CUR" ]; then
    check_port $NEW_HY || { echo -e "${RED}端口 $NEW_HY 被占用${NC}"; return; }
  fi
  if [ "$NEW_VL" != "$VL_CUR" ]; then
    check_port $NEW_VL || { echo -e "${RED}端口 $NEW_VL 被占用${NC}"; return; }
  fi

  # 重新生成配置文件（保留原有 PASS/UUID/SID/PRIV_KEY）
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
    }
  ],
  "outbounds": [{ "type": "direct" }]
}
EOF

  systemctl restart sing-box
  echo -e "${GREEN}配置已更新并重启服务${NC}"
  show_nodes
}

### 输出节点
show_nodes() {
  IP=$(curl -s ipv4.ip.sb)

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
  echo "hy2://$PASS@$IP:$HY_PORT/?insecure=1&alpn=h3#$CUSTOM_NAME"
  echo
  echo -e "VLESS Reality (稳健模式):"
  echo "vless://$UUID@$IP:$VL_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$DOMAIN&fp=chrome&pbk=$PUB_KEY&sid=$SID&type=tcp#$CUSTOM_NAME"
  echo
}

### 菜单
menu() {
  clear
  echo "========== sing-box 管理面板 =========="
  echo "1. 安装"
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
    3) systemctl status sing-box ;;
    4) journalctl -u sing-box -f ;;
    5) systemctl restart sing-box ;;
    6) systemctl stop sing-box; rm -rf $SB_DIR $SERVICE_FILE; echo "已卸载" ;;
    7) modify_config ;;
    0) exit ;;
    *) echo "无效选择" ;;
  esac
}

check_root
menu