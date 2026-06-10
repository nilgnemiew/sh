#!/bin/bash
### 基础路径
SB_DIR="/etc/sing-box"
CERT_DIR="$SB_DIR/cert"
SB_CONFIG="$SB_DIR/config.json"
KEY_FILE="$SB_DIR/reality.key"
SERVICE_FILE="/etc/systemd/system/sing-box.service"
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'
CUSTOM_NAME="SingBox"
### 固定配置值（Reality 和 Hysteria2）
FIXED_VLESS_UUID="93be88a8-1880-4359-90af-fd2d266a9863"
FIXED_HY2_PASS="cc4b969259d0eb84"
FIXED_REALITY_SHORTID="b631f62d"
FIXED_REALITY_PUBKEY="y4_s_qNaoQdxwD91KAZOHlpLcJpaSy0RBVflQv4-Zlw"
FIXED_REALITY_PRIVKEY="SNpaGKzmrS131QIPhl92ato75liiD2_a12EomxDBz3U"
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
### 生成或写入固定 Reality 密钥
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
  # 使用固定值
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
  echo "Hysteria2 密码: $PASS_CUR （固定）"
  echo "VLESS UUID: $UUID_CUR （固定）"
  echo "Reality ShortID: $SID_CUR （固定）"
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
### 输出节点（已修改：添加证书 SHA256 指纹支持）
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

  # 新增：计算自签名证书的 SHA256 指纹（严格按照您提供的 openssl 命令）
  # 用于 Hysteria2 的 pinSHA256 参数，实现证书固定验证（比 insecure=1 更安全）
  FINGERPRINT=""
  if command -v openssl >/dev/null 2>&1 && [ -f "$CERT_DIR/server.crt" ]; then
    FP_RAW=$(openssl x509 -in "$CERT_DIR/server.crt" -noout -fingerprint -sha256 2>/dev/null || true)
    if echo "$FP_RAW" | grep -q "SHA256 Fingerprint="; then
      FINGERPRINT=$(echo "$FP_RAW" | awk -F= '{print $2}' | tr -d ':' | tr 'A-F' 'a-f')
    fi
  fi

  echo
  echo -e "${GREEN}===== 节点配置已生成 =====${NC}"
  echo

  echo -e "Hysteria2 (高速模式):"
  if [ -n "$FINGERPRINT" ]; then
    # 使用 pinSHA256 指纹 + alpn（推荐，更安全，不再默认 insecure=1）
    echo "hy2://$PASS@$IP:$HY_PORT/?pinSHA256=$FINGERPRINT&alpn=h3#$CUSTOM_NAME"
  else
    # 回退到原有方式（当无法获取指纹时）
    echo "hy2://$PASS@$IP:$HY_PORT/?insecure=1&alpn=h3#$CUSTOM_NAME"
  fi
  echo

  echo -e "VLESS Reality (稳健模式):"
  echo "vless://$UUID@$IP:$VL_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$DOMAIN&fp=chrome&pbk=$PUB_KEY&sid=$SID&type=tcp#$CUSTOM_NAME"
  echo

  if [ -n "$FINGERPRINT" ]; then
    echo -e "${GREEN}已为 Hysteria2 节点添加 pinSHA256 指纹${NC}（启用证书验证，更安全）"
    echo "指纹值: $FINGERPRINT"
    echo -e "${YELLOW}提示: 大多数现代客户端（sing-box、Hiddify、Shadowrocket 等）均支持 pinSHA256 参数。${NC}"
    echo -e "${YELLOW}      如果客户端不支持，可手动在链接末尾添加 &insecure=1 并删除 pinSHA256=... 部分。${NC}"
  else
    echo -e "${YELLOW}注意: 未获取到证书指纹（可能缺少 openssl 或证书文件），已回退使用 insecure=1 模式（不验证证书，存在 MITM 风险）。${NC}"
  fi
  echo
}
### 菜单
menu() {
  while true; do
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
   
    [ "$num" != "0" ] && read -p "按 Enter 继续..." && continue
  done
}
check_root
menu
