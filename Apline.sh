#!/bin/bash

### 基础路径
SB_DIR="/etc/sing-box"
CERT_DIR="$SB_DIR/cert"
SB_CONFIG="$SB_DIR/config.json"
KEY_FILE="$SB_DIR/reality.key"
INIT_FILE="/etc/init.d/sing-box"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

### root 检查
check_root() {
  [ "$EUID" -ne 0 ] && echo -e "${RED}请使用 root 执行${NC}" && exit 1
}

### 安装依赖
install_deps() {
  echo -e "${GREEN}正在安装 Alpine 依赖...${NC}"
  apk update
  apk add jq curl openssl bash tar wget
}

### 安装 sing-box
install_singbox() {
  if ! command -v sing-box >/dev/null; then
    echo -e "${GREEN}尝试从仓库安装...${NC}"
    apk add sing-box --repository=http://dl-cdn.alpinelinux.org/alpine/edge/testing/
    
    if [ $? -ne 0 ]; then
       echo -e "${RED}仓库安装失败，手动下载二进制文件...${NC}"
       ARCH=$(uname -m)
       [ "$ARCH" == "x86_64" ] && ARCH="amd64"
       [ "$ARCH" == "aarch64" ] && ARCH="arm64"
       # 自动获取当前最新稳定版
       wget https://github.com/SagerNet/sing-box/releases/download/v1.10.1/sing-box-1.10.1-linux-$ARCH.tar.gz
       tar -zxvf sing-box-*.tar.gz
       cp sing-box-*/sing-box /usr/bin/
       rm -rf sing-box-*
    fi
  fi
}

### 开启 BBR
enable_bbr() {
  # 尝试加载内核模块
  modprobe tcp_bbr 2>/dev/null
  if lsmod | grep -q bbr; then
    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    cat >> /etc/sysctl.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    sysctl -p >/dev/null 2>&1
    echo -e "${GREEN}BBR 开启成功${NC}"
  else
    echo -e "${RED}内核不支持 BBR，跳过...${NC}"
  fi
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
  netstat -an | grep -q ":$1 " && return 1 || return 0
}

### 获取地区信息
get_info() {
  local info=$(curl -s --connect-timeout 5 http://ip-api.com/json/?fields=countryCode,isp)
  REGION=$(echo "$info" | jq -r '.countryCode // "UN"')
  ISP=$(echo "$info" | jq -r '.isp // "Unknown"' | tr ' ' '_')
}

### 生成 OpenRC 初始化脚本
gen_openrc() {
  cat > "$INIT_FILE" <<EOF
#!/sbin/openrc-run

description="sing-box service"
command="/usr/bin/sing-box"
command_args="run -c $SB_CONFIG"
pidfile="/run/\${RC_SVCNAME}.pid"
command_background=true
error_log="/var/log/sing-box.err"

depend() {
    need net
    after firewall
}
EOF
  chmod +x "$INIT_FILE"
}

### 安装配置
install_all() {
  read -p "Hysteria2 端口 [默认 443]: " HY_PORT
  read -p "VLESS Reality 端口 [默认 8443]: " VL_PORT
  HY_PORT=${HY_PORT:-443}
  VL_PORT=${VL_PORT:-8443}

  read -p "请输入 Reality 伪装域名 [默认 www.microsoft.com]: " INPUT_DOMAIN
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

  gen_openrc
  rc-update add sing-box default
  rc-service sing-box restart
  show_nodes
}

### 展示节点信息
show_nodes() {
  IP=$(curl -s ipv4.ip.sb)
  get_info

  HY_PORT=$(jq '.inbounds[]|select(.tag=="hy2")|.listen_port' $SB_CONFIG)
  VL_PORT=$(jq '.inbounds[]|select(.tag=="reality")|.listen_port' $SB_CONFIG)
  PASS=$(jq -r '.inbounds[]|select(.tag=="hy2")|.users[0].password' $SB_CONFIG)
  UUID=$(jq -r '.inbounds[]|select(.tag=="reality")|.users[0].uuid' $SB_CONFIG)
  DOMAIN=$(jq -r '.inbounds[]|select(.tag=="reality")|.tls.server_name' $SB_CONFIG)
  SID=$(jq -r '.inbounds[]|select(.tag=="reality")|.tls.reality.short_id[0]' $SB_CONFIG)
  PUB_KEY=$(awk '/PublicKey/ {print $2}' "$KEY_FILE")

  echo -e "\n${GREEN}===== Alpine Sing-Box 节点配置 =====${NC}"
  echo -e "Hysteria2:"
  echo "hy2://$PASS@$IP:$HY_PORT/?insecure=1&alpn=h3#${REGION}-${ISP}-Hy2"
  echo -e "\nVLESS Reality:"
  echo "vless://$UUID@$IP:$VL_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$DOMAIN&fp=chrome&pbk=$PUB_KEY&sid=$SID&type=tcp#${REGION}-${ISP}-Reality"
}

### 菜单
menu() {
  clear
  echo "========== Alpine sing-box 管理面板 =========="
  echo "1. 安装配置 (Hy2 + Reality)"
  echo "2. 查看节点信息"
  echo "3. 服务状态"
  echo "4. 重启服务"
  echo "5. 卸载"
  echo "0. 退出"
  echo "----------------------------------------------"
  read -p "选择 [0-5]: " num

  case $num in
    1) install_deps; install_singbox; enable_bbr; install_all ;;
    2) [ -f "$SB_CONFIG" ] && show_nodes || echo "尚未安装" ;;
    3) rc-service sing-box status ;;
    4) rc-service sing-box restart ;;
    5) rc-service sing-box stop; rc-update del sing-box; rm -rf $SB_DIR $INIT_FILE; echo "卸载完成" ;;
    0) exit ;;
    *) echo "无效选择" ;;
  esac
}

check_root
menu
