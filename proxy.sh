#!/bin/bash

### 基础路径
SB_DIR="/etc/sing-box"
CERT_DIR="$SB_DIR/cert"
SB_CONFIG="$SB_DIR/config.json"
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
  # 自动识别包管理器
  if command -v apt >/dev/null; then
    apt update && apt install -y jq curl openssl
  elif command -v yum >/dev/null; then
    yum install -y jq curl openssl
  fi
}

### 安装 sing-box
install_singbox() {
  if ! command -v sing-box >/dev/null; then
    echo -e "${GREEN}正在安装 sing-box...${NC}"
    bash <(curl -fsSL https://sing-box.app/install.sh)
  fi
}

### 开启 BBR
enable_bbr() {
  if ! grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf; then
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1
  fi
}

### 生成自签证书
gen_cert() {
  mkdir -p "$CERT_DIR"
  if [ ! -f "$CERT_DIR/server.key" ]; then
    openssl req -x509 -nodes -newkey rsa:2048 \
      -keyout "$CERT_DIR/server.key" \
      -out "$CERT_DIR/server.crt" \
      -days 3650 \
      -subj "/C=US/O=SingBox/CN=SingBox"
  fi
}

### 端口检测
check_port() {
  ss -lntup | grep -q ":$1 " && return 1 || return 0
}

### 写入配置文件逻辑
write_config() {
  local port=$1
  local pass=$2
  
  cat > "$SB_CONFIG" <<EOF
{
  "log": { "level": "info" },
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": $port,
      "users": [{ "password": "$pass" }],
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "$CERT_DIR/server.crt",
        "key_path": "$CERT_DIR/server.key"
      }
    }
  ],
  "outbounds": [{ "type": "direct" }]
}
EOF
}

### 安装配置
install_all() {
  read -p "Hysteria2 监听端口 [默认 443]: " HY_PORT
  HY_PORT=${HY_PORT:-443}

  check_port "$HY_PORT" || { echo -e "${RED}错误: 端口 $HY_PORT 被占用${NC}"; return; }

  PASS=$(openssl rand -hex 12)
  gen_cert
  mkdir -p "$SB_DIR"
  
  write_config "$HY_PORT" "$PASS"

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

### 修改配置
modify_config() {
  [ -f "$SB_CONFIG" ] || { echo -e "${RED}未检测到配置文件${NC}"; return; }

  local HY_CUR=$(jq '.inbounds[]|select(.type=="hysteria2")|.listen_port' $SB_CONFIG)
  local PASS_CUR=$(jq -r '.inbounds[]|select(.type=="hysteria2")|.users[0].password' $SB_CONFIG)

  echo -e "\n${GREEN}当前 Hysteria2 配置:${NC}"
  echo "端口: $HY_CUR"
  echo "密码: $PASS_CUR"
  echo

  read -p "请输入新端口 [回车跳过]: " NEW_PORT
  read -p "请输入新密码 [回车跳过]: " NEW_PASS

  NEW_PORT=${NEW_PORT:-$HY_CUR}
  NEW_PASS=${NEW_PASS:-$PASS_CUR}

  if [ "$NEW_PORT" != "$HY_CUR" ]; then
    check_port "$NEW_PORT" || { echo -e "${RED}端口 $NEW_PORT 被占用${NC}"; return; }
  fi

  write_config "$NEW_PORT" "$NEW_PASS"
  systemctl restart sing-box
  echo -e "${GREEN}配置已更新${NC}"
  show_nodes
}

### 获取地区信息
get_info() {
  local info=$(curl -s --connect-timeout 5 http://ip-api.com/json/?fields=countryCode,isp)
  REGION=$(echo "$info" | jq -r '.countryCode // "UN"')
  ISP=$(echo "$info" | jq -r '.isp // "Server"' | tr ' ' '_')
}

### 输出节点
show_nodes() {
  [ -f "$SB_CONFIG" ] || return
  
  local IP=$(curl -s ipv4.ip.sb || curl -s ifconfig.me)
  get_info

  local HY_PORT=$(jq '.inbounds[]|select(.type=="hysteria2")|.listen_port' $SB_CONFIG)
  local PASS=$(jq -r '.inbounds[]|select(.type=="hysteria2")|.users[0].password' $SB_CONFIG)

  echo -e "\n${GREEN}===== Hysteria2 节点信息 =====${NC}"
  echo -e "说明: 由于使用的是自签证书，请在客户端开启 'Allow Insecure' (允许不安全连接)\n"
  echo -e "${GREEN}通用链接:${NC}"
  echo "hy2://$PASS@$IP:$HY_PORT/?insecure=1&alpn=h3#${REGION}-${ISP}"
  echo -e "\n=============================="
}

### 菜单
menu() {
  clear
  echo "========== sing-box (Hy2 Only) =========="
  echo "1. 安装 Hysteria2"
  echo "2. 查看节点信息"
  echo "3. 运行状态"
  echo "4. 实时日志"
  echo "5. 重启服务"
  echo "6. 彻底卸载"
  echo "7. 修改端口/密码"
  echo "0. 退出"
  echo "========================================="
  read -p "请选择 [0-7]: " num

  case $num in
    1) install_deps; install_singbox; enable_bbr; install_all ;;
    2) show_nodes ;;
    3) systemctl status sing-box ;;
    4) journalctl -u sing-box -f ;;
    5) systemctl restart sing-box ;;
    6) systemctl stop sing-box; systemctl disable sing-box; rm -rf $SB_DIR $SERVICE_FILE; echo "已卸载" ;;
    7) modify_config ;;
    0) exit ;;
    *) echo "无效选择" ;;
  esac
}

check_root
menu
