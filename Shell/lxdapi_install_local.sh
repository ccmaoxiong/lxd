#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_DIR="${LXDAPI_INSTALL_DIR:-/opt/lxdapi}"
FORCE_INSTALL="${FORCE_INSTALL:-0}"
SKIP_SERVICE="${SKIP_SERVICE:-0}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "$1"; }
ok() { log "${GREEN}[OK]${NC} $1"; }
info() { log "${BLUE}[INFO]${NC} $1"; }
warn() { log "${YELLOW}[WARN]${NC} $1"; }
err() { log "${RED}[ERR]${NC} $1"; exit 1; }

reading() { read -rp "$(echo -e "${GREEN}$1${NC}")" "$2"; }

if [ "$(id -u)" -ne 0 ]; then
    err "请使用 root 运行，或使用 sudo bash $0"
fi

case "$(uname -m)" in
    x86_64|amd64)
        ARCH="amd64"
        ;;
    aarch64|arm64)
        ARCH="arm64"
        ;;
    *)
        err "不支持的架构: $(uname -m)"
        ;;
esac

if [ -n "${1:-}" ]; then
    BINARY="$1"
elif [ -f "$SCRIPT_DIR/lxdapi-$ARCH" ]; then
    BINARY="$SCRIPT_DIR/lxdapi-$ARCH"
else
    BINARY="$ROOT_DIR/lxdapi/lxdapi-$ARCH"
fi

if [ -d "$(dirname "$BINARY")/configs" ]; then
    SOURCE_DIR="$(cd "$(dirname "$BINARY")" && pwd)"
elif [ -d "$ROOT_DIR/lxdapi/configs" ]; then
    SOURCE_DIR="$ROOT_DIR/lxdapi"
else
    err "未找到 configs 目录，请确认二进制位于 lxdapi 目录或已包含 configs/plugins"
fi

if [ ! -x "$BINARY" ] && [ ! -f "$BINARY" ]; then
    err "未找到编译产物: $BINARY，请先编译或传入二进制路径"
fi

case "$INSTALL_DIR" in
    /|/opt|/usr|/etc|/root|/home|/var)
        err "LXDAPI_INSTALL_DIR 不允许设置为 $INSTALL_DIR"
        ;;
esac

if [ "$INSTALL_DIR" = "$ROOT_DIR" ] || [ "$INSTALL_DIR" = "$ROOT_DIR/lxdapi" ]; then
    err "LXDAPI_INSTALL_DIR 不允许设置为仓库目录: $INSTALL_DIR"
fi

random_hex() {
    local length="$1"
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex "$length"
    else
        tr -dc 'a-f0-9' </dev/urandom | head -c "$((length * 2))"
    fi
}

sed_escape() {
    printf '%s' "$1" | sed 's/[\\&|]/\\&/g'
}

deploy_binary() {
    if [ -d "$INSTALL_DIR" ] && [ "$FORCE_INSTALL" != "1" ]; then
        warn "安装目录已存在: $INSTALL_DIR"
        reading "是否覆盖安装？(y/n) [y]：" overwrite
        overwrite=${overwrite:-y}
        if [[ ! "$overwrite" =~ ^[yY]$ ]]; then
            err "已取消安装"
        fi
    fi

    log "安装到 $INSTALL_DIR ..."
    rm -rf "$INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"

    install -m 755 "$BINARY" "$INSTALL_DIR/lxdapi-$ARCH"
    cp -r "$SOURCE_DIR/configs" "$INSTALL_DIR/"

    if [ -d "$SOURCE_DIR/plugins/opengfw" ]; then
        mkdir -p "$INSTALL_DIR/plugins/opengfw/bin" "$INSTALL_DIR/plugins/opengfw/data"
        if [ -f "$SOURCE_DIR/plugins/opengfw/bin/OpenGFW-linux-$ARCH" ]; then
            cp "$SOURCE_DIR/plugins/opengfw/bin/OpenGFW-linux-$ARCH" "$INSTALL_DIR/plugins/opengfw/bin/"
        fi
        cp "$SOURCE_DIR"/plugins/opengfw/data/*.dat "$INSTALL_DIR/plugins/opengfw/data/" 2>/dev/null || true
    fi

    if [ -d "$SOURCE_DIR/plugins/nginx" ]; then
        mkdir -p "$INSTALL_DIR/plugins/nginx/conf/sites" "$INSTALL_DIR/plugins/nginx/ssl"
        cp "$SOURCE_DIR"/plugins/nginx/*.tmpl "$INSTALL_DIR/plugins/nginx/" 2>/dev/null || true
    fi

    chmod +x "$INSTALL_DIR/lxdapi-$ARCH"
    ok "程序安装完成: $INSTALL_DIR/lxdapi-$ARCH"
}

configure_lxdapi() {
    config_file="$INSTALL_DIR/configs/config.yaml"

    reading "请输入服务端口 [8443]：" server_port
    server_port=${server_port:-8443}

    reading "请输入API密钥 [随机生成]：" api_hash
    if [ -z "$api_hash" ]; then
        api_hash=$(random_hex 16)
        ok "API密钥已生成: $api_hash"
    fi

    reading "请输入管理员用户名 [admin]：" admin_user
    admin_user=${admin_user:-admin}

    reading "请输入管理员密码 [随机生成]：" admin_pass
    if [ -z "$admin_pass" ]; then
        admin_pass=$(random_hex 8)
        ok "管理员密码已生成: $admin_pass"
    fi

    session_secret=$(random_hex 16)

    reading "请输入流量采集间隔秒数 [20]：" traffic_interval
    traffic_interval=${traffic_interval:-20}

    reading "请输入流量批量更新数量 [10]：" traffic_batch_size
    traffic_batch_size=${traffic_batch_size:-10}

    reading "是否启用 Nginx 反向代理插件？ y/n [n]：" nginx_enabled
    nginx_enabled=${nginx_enabled:-n}
    if [[ "$nginx_enabled" =~ ^[yY]$ ]]; then
        nginx_enabled_value="true"
    else
        nginx_enabled_value="false"
    fi

    sed -i "s|__SERVER_PORT__|$server_port|g" "$config_file"
    sed -i "s|__API_HASH__|$(sed_escape "$api_hash")|g" "$config_file"
    sed -i "s|__ADMIN_USER__|$(sed_escape "$admin_user")|g" "$config_file"
    sed -i "s|__ADMIN_PASS__|$(sed_escape "$admin_pass")|g" "$config_file"
    sed -i "s|__SESSION_SECRET__|$(sed_escape "$session_secret")|g" "$config_file"
    sed -i "s|__TRAFFIC_INTERVAL__|$traffic_interval|g" "$config_file"
    sed -i "s|__TRAFFIC_BATCH_SIZE__|$traffic_batch_size|g" "$config_file"
    sed -i "s|__AUTO_CLEANUP_DAYS__|7|g" "$config_file"
    sed -i "s|__TASK_BACKEND__|memory|g" "$config_file"
    sed -i "s|__DB_TYPE__|sqlite|g" "$config_file"
    sed -i "s|__REDIS_HOST__|localhost|g" "$config_file"
    sed -i "s|__REDIS_PORT__|6379|g" "$config_file"
    sed -i "s|__REDIS_PASSWORD__||g" "$config_file"
    sed -i "s|__REDIS_DB__|0|g" "$config_file"
    sed -i "s|__MYSQL_HOST__|localhost|g" "$config_file"
    sed -i "s|__MYSQL_PORT__|3306|g" "$config_file"
    sed -i "s|__MYSQL_USER__|root|g" "$config_file"
    sed -i "s|__MYSQL_PASSWORD__||g" "$config_file"
    sed -i "s|__MYSQL_DATABASE__|lxdapi|g" "$config_file"
    sed -i "s|__POSTGRES_HOST__|localhost|g" "$config_file"
    sed -i "s|__POSTGRES_PORT__|5432|g" "$config_file"
    sed -i "s|__POSTGRES_USER__|postgres|g" "$config_file"
    sed -i "s|__POSTGRES_PASSWORD__||g" "$config_file"
    sed -i "s|__POSTGRES_DATABASE__|lxdapi|g" "$config_file"
    sed -i "s|__POSTGRES_SSLMODE__|disable|g" "$config_file"
    sed -i "s|__NGINX_ENABLED__|$nginx_enabled_value|g" "$config_file"

    ok "配置已写入: $config_file"
}

setup_service() {
    service_file="/etc/systemd/system/lxdapi.service"

    cat > "$service_file" <<EOF
[Unit]
Description=LXD API Server
After=network.target lxd.service
Wants=lxd.service

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin"
ExecStart=$INSTALL_DIR/lxdapi-$ARCH
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable lxdapi >/dev/null 2>&1 || true
    systemctl restart lxdapi

    sleep 2
    if systemctl is-active --quiet lxdapi; then
        ok "lxdapi 服务已启动"
    else
        warn "lxdapi 服务可能启动失败，查看日志: journalctl -u lxdapi -n 50 --no-pager"
    fi
}

main() {
    echo
    echo "========================================"
    echo "  本地编译产物安装脚本"
    echo "  $BINARY"
    echo "========================================"
    echo

    deploy_binary

    reading "是否进行交互配置？(y/n) [y]：" configure_confirm
    configure_confirm=${configure_confirm:-y}
    if [[ "$configure_confirm" =~ ^[yY]$ ]]; then
        configure_lxdapi
    else
        warn "跳过配置，请手动编辑 $INSTALL_DIR/configs/config.yaml"
    fi

    if [ "$SKIP_SERVICE" = "1" ]; then
        warn "已跳过 systemd 服务安装"
        info "手动启动: $INSTALL_DIR/lxdapi-$ARCH"
    elif command -v systemctl >/dev/null 2>&1; then
        setup_service
    else
        warn "未检测到 systemd，跳过服务安装"
        info "手动启动: $INSTALL_DIR/lxdapi-$ARCH"
    fi

    echo
    echo "========================================"
    echo "        安装完成"
    echo "========================================"
    echo
    info "安装目录: $INSTALL_DIR"
    info "程序路径: $INSTALL_DIR/lxdapi-$ARCH"
    info "服务端口: ${server_port:-未配置}"
    info "API密钥: ${api_hash:-未配置}"
    info "管理员用户: ${admin_user:-未配置}"
    info "管理员密码: ${admin_pass:-未配置}"
}

main
