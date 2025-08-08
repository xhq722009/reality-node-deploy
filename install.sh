#!/usr/bin/env bash
set -euo pipefail

NODE_NAME="gcp-node-$(hostname)"
REALITY_SNI="www.apple.com"
PORT_REALITY=8443
SINGBOX_BIN="/usr/local/bin/sing-box"
CLASH_OUTPUT_DIR="/var/www/nodes"

log() { echo "[$(date '+%F %T')] $*"; }

ensure_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "请用 root 或 sudo 运行此脚本"
    exit 1
  fi
}

install_dependencies() {
  log "安装依赖..."
  apt-get update
  apt-get install -y curl wget tar unzip ca-certificates jq nginx ufw
}

install_singbox() {
  if [ -x "$SINGBOX_BIN" ]; then
    log "sing-box 已安装，跳过"
    return
  fi
  log "下载安装 sing-box..."

  latest_version=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r '.tag_name')
  latest_version_no_v=${latest_version#v}  # 去掉前缀v
  if [ -z "$latest_version" ] || [ "$latest_version" = "null" ]; then
    echo "获取 sing-box 最新版本失败"
    exit 1
  fi

  url="https://github.com/SagerNet/sing-box/releases/download/${latest_version}/sing-box-linux-amd64-${latest_version_no_v}.tar.gz"
  curl -fsSL "$url" -o /tmp/singbox.tar.gz || {
    echo "下载 sing-box 失败，检查链接或网络"
    exit 1
  }
  tar -C /tmp -xzf /tmp/singbox.tar.gz
  mv /tmp/sing-box "$SINGBOX_BIN"
  chmod +x "$SINGBOX_BIN"
}

generate_reality_keypair() {
  if [ -f /etc/sing-box/reality_key.json ]; then
    log "Reality key 已存在"
  else
    log "生成 Reality 密钥..."
    mkdir -p /etc/sing-box
    $SINGBOX_BIN key generate -t reality > /etc/sing-box/reality_key.json
  fi
}

read_key() {
  jq -r ".$1" /etc/sing-box/reality_key.json
}

generate_singbox_config() {
  local pubkey=$1
  local privkey=$2
  mkdir -p /etc/sing-box
  cat > /etc/sing-box/config.json <<EOF
{
  "log": { "level": "info" },
  "inbounds": [{
    "type": "trojan",
    "tag": "reality-in",
    "listen": "0.0.0.0",
    "listen_port": ${PORT_REALITY},
    "tls": { "enabled": true, "alpn": ["h2","http/1.1"] },
    "reality": {
      "handshake": { "server": "${REALITY_SNI}" },
      "private_key": "${privkey}",
      "public_key": "${pubkey}"
    }
  }],
  "outbounds": [{ "type": "direct" }]
}
EOF
}

setup_nginx() {
  mkdir -p "$CLASH_OUTPUT_DIR"
  cat > /etc/nginx/sites-available/nodes <<EOF
server {
  listen 8080 default_server;
  listen [::]:8080 default_server;
  root $CLASH_OUTPUT_DIR;
  location / {
    autoindex on;
  }
}
EOF
  ln -sf /etc/nginx/sites-available/nodes /etc/nginx/sites-enabled/nodes
  systemctl restart nginx
}

generate_clash_yaml() {
  local ip=$(curl -s icanhazip.com)
  mkdir -p "$CLASH_OUTPUT_DIR"
  cat > "$CLASH_OUTPUT_DIR/$NODE_NAME.yaml" <<EOF
proxies:
  - name: "${NODE_NAME}-Reality"
    type: trojan
    server: ${ip}
    port: ${PORT_REALITY}
    password: ""
    sni: "${REALITY_SNI}"
    alpn:
      - h2
      - http/1.1
    udp: true
EOF
  log "Clash 配置文件生成于 $CLASH_OUTPUT_DIR/$NODE_NAME.yaml"
}

setup_firewall() {
  ufw allow ${PORT_REALITY}/tcp
  ufw allow 8080/tcp
  ufw --force enable
}

setup_systemd_service() {
  cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
After=network.target

[Service]
ExecStart=$SINGBOX_BIN run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now sing-box.service
}

main() {
  ensure_root
  install_dependencies
  install_singbox
  generate_reality_keypair

  local pubkey=$(read_key public_key)
  local privkey=$(read_key secret_key)

  generate_singbox_config "$pubkey" "$privkey"
  setup_nginx
  generate_clash_yaml
  setup_firewall
  setup_systemd_service

  log "安装完成！节点配置文件路径：$CLASH_OUTPUT_DIR/$NODE_NAME.yaml"
  log "请用支持 Reality 协议的客户端导入该配置。"
}

main "$@"
