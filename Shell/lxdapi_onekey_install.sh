#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

INSTALL_DIR="${LXDAPI_INSTALL_DIR:-/opt/lxdapi}"
FORCE_INSTALL="${FORCE_INSTALL:-0}"
SKIP_SERVICE="${SKIP_SERVICE:-0}"
SKIP_LXD="${SKIP_LXD:-0}"
LXD_NETWORK_FORCE="${LXD_NETWORK_FORCE:-0}"
AUTO_INSTALL="${AUTO_INSTALL:-0}"
NGINX_ENABLED="${NGINX_ENABLED:-0}"
SNAP_CHANNEL="${SNAP_CHANNEL:-latest/stable}"
SNAPD_CHANNEL="${SNAPD_CHANNEL:-latest/stable}"
GITHUB_OWNER="${GITHUB_OWNER:-ccmaoxiong}"
GITHUB_REPO="${GITHUB_REPO:-lxd}"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
GITEE_OWNER="${GITEE_OWNER:-ccmaoxiong}"
GITEE_REPO="${GITEE_REPO:-lxd}"

if [ "$AUTO_INSTALL" = "0" ] && [ ! -t 0 ]; then
    AUTO_INSTALL=1
fi

TEMP_DOWNLOAD_DIR=""
cleanup() {
    if [ -n "$TEMP_DOWNLOAD_DIR" ]; then
        rm -rf "$TEMP_DOWNLOAD_DIR"
    fi
}
trap cleanup EXIT

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

reading() {
    read -rp "$(echo -e "${GREEN}$1${NC}")" "$2"
}

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

SYSTEM_ID="$(sed -n 's/^ID=//p' /etc/os-release 2>/dev/null | tr -d '"')"
case "$SYSTEM_ID" in
    debian|ubuntu|astra)
        ;;
    *)
        err "此脚本仅支持 Debian 和 Ubuntu 系统"
        ;;
esac

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

check_install_dir() {
    case "$INSTALL_DIR" in
        /|/opt|/usr|/etc|/root|/home|/var)
            err "LXDAPI_INSTALL_DIR 不允许设置为 $INSTALL_DIR"
            ;;
    esac

    if [ "$INSTALL_DIR" = "$REPO_DIR" ] || [ "$INSTALL_DIR" = "$REPO_DIR/lxdapi" ]; then
        err "LXDAPI_INSTALL_DIR 不允许设置为仓库目录: $INSTALL_DIR"
    fi

    if [ "$INSTALL_DIR" = "$SCRIPT_DIR" ] || { [ -n "${SOURCE_DIR:-}" ] && [ "$INSTALL_DIR" = "$SOURCE_DIR" ]; }; then
        err "LXDAPI_INSTALL_DIR 不允许设置为脚本或源码所在目录: $INSTALL_DIR"
    fi
}

prepare_system() {
    info "更新软件包列表..."
    apt-get update

    info "安装基础软件包..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl wget nftables openssl
    ok "基础软件包准备完成"
}

acquire_backend() {
    if [ -n "${1:-}" ]; then
        BINARY="$1"
        if [ -d "$(dirname "$BINARY")/configs" ]; then
            SOURCE_DIR="$(cd "$(dirname "$BINARY")" && pwd)"
        elif [ -d "$REPO_DIR/lxdapi/configs" ]; then
            SOURCE_DIR="$REPO_DIR/lxdapi"
        else
            err "未找到 configs 目录，请确认二进制位于 lxdapi 目录或已包含 configs"
        fi
        if [ ! -f "$BINARY" ]; then
            err "未找到编译产物: $BINARY"
        fi
        return
    fi

    if [ -n "${LXDAPI_SOURCE_DIR:-}" ]; then
        if [ ! -d "$LXDAPI_SOURCE_DIR" ]; then
            err "LXDAPI_SOURCE_DIR 不存在: $LXDAPI_SOURCE_DIR"
        fi
        SOURCE_DIR="$(cd "$LXDAPI_SOURCE_DIR" && pwd)"
        BINARY="$SOURCE_DIR/lxdapi-$ARCH"
        if [ ! -f "$BINARY" ] || [ ! -d "$SOURCE_DIR/configs" ]; then
            err "LXDAPI_SOURCE_DIR 不是有效发布包目录: $LXDAPI_SOURCE_DIR"
        fi
        info "使用指定发布包目录: $BINARY"
        return
    fi

    if [ -f "$SCRIPT_DIR/lxdapi-$ARCH" ] && [ -d "$SCRIPT_DIR/configs" ]; then
        BINARY="$SCRIPT_DIR/lxdapi-$ARCH"
        SOURCE_DIR="$SCRIPT_DIR"
        info "使用发布包内后端程序: $BINARY"
        return
    fi

    if [ -f "$REPO_DIR/lxdapi/lxdapi-$ARCH" ] && [ -d "$REPO_DIR/lxdapi/configs" ]; then
        BINARY="$REPO_DIR/lxdapi/lxdapi-$ARCH"
        SOURCE_DIR="$REPO_DIR/lxdapi"
        info "使用本地编译产物: $BINARY"
        return
    fi

    if [ -f "$REPO_DIR/lxdapi/build.sh" ]; then
        info "未找到编译产物，开始自动编译..."
        bash "$REPO_DIR/lxdapi/build.sh"
        BINARY="$REPO_DIR/lxdapi/lxdapi-$ARCH"
        SOURCE_DIR="$REPO_DIR/lxdapi"
        return
    fi

    download_from_release
}

download_from_release() {
    local tag url archive temp_file

    info "未找到本地源码或编译产物，开始下载发布包..."

    archive="lxdapi-linux-${ARCH}.tar.gz"
    TEMP_DOWNLOAD_DIR="$(mktemp -d)"

    if [ -n "${LXDAPI_RELEASE_URL:-}" ]; then
        url="$LXDAPI_RELEASE_URL"
    else
        tag="${LXDAPI_TAG:-}"
        if [ -z "$tag" ]; then
            info "获取最新版本号..."
            tag="$(curl -fsSL --connect-timeout 20 "https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/releases/latest" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')"
        fi
        if [ -z "$tag" ]; then
            err "无法获取最新版本，请设置 LXDAPI_RELEASE_URL 或 LXDAPI_TAG"
        fi
        url="https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/releases/download/${tag}/${archive}"
    fi

    info "下载地址: $url"
    temp_file="$(mktemp)"
    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 3 --connect-timeout 20 -o "$temp_file" "$url"
    else
        wget -O "$temp_file" "$url"
    fi

    mkdir -p "$TEMP_DOWNLOAD_DIR/lxdapi"
    tar -xzf "$temp_file" -C "$TEMP_DOWNLOAD_DIR/lxdapi" --strip-components=1
    rm -f "$temp_file"

    BINARY="$TEMP_DOWNLOAD_DIR/lxdapi/lxdapi-$ARCH"
    SOURCE_DIR="$TEMP_DOWNLOAD_DIR/lxdapi"

    if [ ! -f "$BINARY" ] || [ ! -d "$SOURCE_DIR/configs" ]; then
        err "发布包内容不完整或架构不匹配"
    fi
    ok "发布包下载完成: $BINARY"
}

snapd_version() {
    snap version 2>/dev/null | awk '$1 == "snapd" {print $2; exit}'
}

version_at_least() {
    local left="$1"
    local right="$2"
    [ "$(printf '%s\n%s\n' "$left" "$right" | sort -V | head -n 1)" = "$right" ]
}

ensure_snapd_current() {
    local current
    current="$(snapd_version)"
    if [ -n "$current" ] && version_at_least "$current" "2.75"; then
        ok "snapd 版本满足要求: $current"
        return
    fi

    info "当前 snapd: ${current:-未知}，需要 2.75+，开始刷新 snapd..."
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        current="$(snapd_version)"
        if [ -z "$current" ] || ! version_at_least "$current" "2.75"; then
            snap refresh snapd --channel="$SNAPD_CHANNEL" >/dev/null 2>&1 || snap install snapd --channel="$SNAPD_CHANNEL" >/dev/null 2>&1 || true
            sleep 5
        fi
        current="$(snapd_version)"
        if [ -n "$current" ] && version_at_least "$current" "2.75"; then
            ok "snapd 已更新到 $current"
            systemctl restart snapd >/dev/null 2>&1 || true
            sleep 2
            return
        fi
    done

    warn "未能确认 snapd 已更新到 2.75+，继续尝试安装 LXD"
}

install_lxd_backend() {
    if command -v lxc >/dev/null 2>&1; then
        ok "LXD 已安装: $(lxc version 2>/dev/null | head -n 1 || true)"
        return
    fi

    info "安装 snapd..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y snapd

    systemctl enable --now snapd >/dev/null 2>&1 || true

    for _ in 1 2 3 4 5; do
        if snap wait system seed.loaded >/dev/null 2>&1; then
            break
        fi
        sleep 2
    done

    if [ -n "${SNAP_PROXY_HTTP:-}" ]; then
        snap set system proxy.http="$SNAP_PROXY_HTTP" || true
    fi
    if [ -n "${SNAP_PROXY_HTTPS:-}" ]; then
        snap set system proxy.https="$SNAP_PROXY_HTTPS" || true
    fi
    if [ -n "${SNAP_PROXY_HTTP:-}" ] || [ -n "${SNAP_PROXY_HTTPS:-}" ]; then
        systemctl restart snapd >/dev/null 2>&1 || true
        sleep 2
    fi

    ensure_snapd_current

    install_lxd_snap() {
        local attempt success=0
        for attempt in 1 2 3; do
            info "安装 LXD (第 $attempt/3 次)..."
            if snap install lxd --channel="$SNAP_CHANNEL"; then
                success=1
                break
            fi
            warn "snap 请求失败，10 秒后重试..."
            sleep 10
            systemctl restart snapd >/dev/null 2>&1 || true
        done
        if [ "$success" != "1" ]; then
            err "LXD snap 安装失败，请检查网络或代理后重试"
        fi
    }

    install_lxd_snap
    snap alias lxd.lxc lxc 2>/dev/null || true
    snap alias lxd.lxd lxd 2>/dev/null || true
    export PATH="$PATH:/snap/bin"

    if [ ! -f /etc/profile.d/snap.sh ]; then
        echo 'export PATH=$PATH:/snap/bin' > /etc/profile.d/snap.sh
    fi

    if ! command -v lxc >/dev/null 2>&1; then
        err "lxc 路径有问题，请检查 snap alias"
    fi
    ok "LXD 安装完成"
}

normalize_bool() {
    case "$1" in
        1|y|Y|yes|Yes|true|TRUE)
            echo true
            ;;
        *)
            echo false
            ;;
    esac
}

configure_lxd_network_settings() {
    if [ "$AUTO_INSTALL" = "1" ]; then
        LXD_NETWORK_NAME="${LXD_NETWORK_NAME:-lxdbr0}"
        LXD_IPV4_ADDRESS="${LXD_IPV4_ADDRESS:-10.66.0.1/16}"
        LXD_IPV4_NAT="$(normalize_bool "${LXD_IPV4_NAT:-true}")"
        LXD_IPV6_ADDRESS="${LXD_IPV6_ADDRESS:-fd66:6666::1/64}"
        LXD_IPV6_NAT="$(normalize_bool "${LXD_IPV6_NAT:-true}")"
    else
        LXD_NETWORK_NAME="${LXD_NETWORK_NAME:-}"
        if [ -z "$LXD_NETWORK_NAME" ]; then
            reading "请输入 LXD 网络名称 [lxdbr0]：" LXD_NETWORK_NAME
        fi
        LXD_NETWORK_NAME=${LXD_NETWORK_NAME:-lxdbr0}

        reading "是否启用 IPv4？y/n [y]：" enable_ipv4
        if [[ ${enable_ipv4:-y} =~ ^[yY]$ ]]; then
            reading "请输入 IPv4 网段 [10.66.0.1/16]：" ipv4_address
            LXD_IPV4_ADDRESS=${ipv4_address:-10.66.0.1/16}
            reading "是否启用 IPv4 NAT？y/n [y]：" ipv4_nat
            LXD_IPV4_NAT=$(normalize_bool "${ipv4_nat:-y}")
        else
            LXD_IPV4_ADDRESS="none"
            LXD_IPV4_NAT="false"
        fi

        reading "是否启用 IPv6？y/n [y]：" enable_ipv6
        if [[ ${enable_ipv6:-y} =~ ^[yY]$ ]]; then
            reading "请输入 IPv6 网段 [fd66:6666::1/64]：" ipv6_address
            LXD_IPV6_ADDRESS=${ipv6_address:-fd66:6666::1/64}
            reading "是否启用 IPv6 NAT？y/n [y]：" ipv6_nat
            LXD_IPV6_NAT=$(normalize_bool "${ipv6_nat:-y}")
        else
            LXD_IPV6_ADDRESS="none"
            LXD_IPV6_NAT="false"
        fi
    fi

    info "LXD 网络配置: $LXD_NETWORK_NAME (IPv4=$LXD_IPV4_ADDRESS, IPv6=$LXD_IPV6_ADDRESS)"
}

init_lxd_network() {
    local lxc_bin

    if [ "$SKIP_LXD" = "1" ]; then
        info "已跳过 LXD 安装和初始化"
        return
    fi

    if command -v lxc >/dev/null 2>&1; then
        lxc_bin="$(command -v lxc)"
    elif [ -x /snap/bin/lxc ]; then
        lxc_bin="/snap/bin/lxc"
    else
        warn "未找到 lxc 命令，跳过 LXD 网络初始化"
        return
    fi

    local network_name="${LXD_NETWORK_NAME:-lxdbr0}"
    local network_exists=0

    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if "$lxc_bin" network show "$network_name" >/dev/null 2>&1; then
            network_exists=1
            break
        fi
        sleep 1
    done

    if [ "$network_exists" = "1" ]; then
        if [ "$LXD_NETWORK_FORCE" = "1" ]; then
            warn "检测到 $network_name，启用强制更新网络配置..."
            configure_lxd_network_settings
            "$lxc_bin" config set images.auto_update_interval "0"
            "$lxc_bin" network set "$network_name" ipv4.address "$LXD_IPV4_ADDRESS"
            "$lxc_bin" network set "$network_name" ipv4.nat "$LXD_IPV4_NAT"
            "$lxc_bin" network set "$network_name" ipv6.address "$LXD_IPV6_ADDRESS"
            "$lxc_bin" network set "$network_name" ipv6.nat "$LXD_IPV6_NAT"
            ok "$network_name 网络配置已更新"
        else
            ok "$network_name 网络已存在"
            return
        fi
        return
    fi

    configure_lxd_network_settings
    network_name="$LXD_NETWORK_NAME"

    info "初始化 LXD 网络: $network_name ..."
    "$lxc_bin" config set images.auto_update_interval "0"
    "$lxc_bin" network create "$network_name" --type bridge \
        ipv4.address="$LXD_IPV4_ADDRESS" ipv4.nat="$LXD_IPV4_NAT" \
        ipv6.address="$LXD_IPV6_ADDRESS" ipv6.nat="$LXD_IPV6_NAT"

    if ! "$lxc_bin" profile show default >/dev/null 2>&1; then
        "$lxc_bin" profile create default >/dev/null
    fi
    local default_network
    default_network="$("$lxc_bin" profile device get default eth0 network 2>/dev/null || true)"
    if [ "$default_network" != "$network_name" ]; then
        "$lxc_bin" profile device remove default eth0 >/dev/null 2>&1 || true
        "$lxc_bin" profile device add default eth0 nic network="$network_name" name=eth0
    fi

    if "$lxc_bin" network show "$network_name" >/dev/null 2>&1; then
        ok "$network_name 网络初始化完成"
    else
        warn "$network_name 网络初始化后未检测到，请手动执行 lxd init"
    fi
}

deploy_backend() {
    check_install_dir

    if [ -d "$INSTALL_DIR" ] && [ "$FORCE_INSTALL" != "1" ]; then
        if [ "$AUTO_INSTALL" = "1" ]; then
            FORCE_INSTALL=1
        else
            warn "安装目录已存在: $INSTALL_DIR"
            reading "是否覆盖安装？(y/n) [y]：" overwrite
            overwrite=${overwrite:-y}
            if [[ ! "$overwrite" =~ ^[yY]$ ]]; then
                err "已取消安装"
            fi
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
    ok "后端程序安装完成: $INSTALL_DIR/lxdapi-$ARCH"
}

configure_backend() {
    local config_file="$INSTALL_DIR/configs/config.yaml"
    local nginx_enabled_value

    if [ "$AUTO_INSTALL" = "1" ]; then
        SERVER_PORT="${SERVER_PORT:-8443}"
        API_HASH="${API_HASH:-$(random_hex 16)}"
        ADMIN_USER="${ADMIN_USER:-admin}"
        ADMIN_PASS="${ADMIN_PASS:-$(random_hex 8)}"
        TRAFFIC_INTERVAL="${TRAFFIC_INTERVAL:-20}"
        TRAFFIC_BATCH_SIZE="${TRAFFIC_BATCH_SIZE:-10}"
        AUTO_CLEANUP_DAYS="${AUTO_CLEANUP_DAYS:-7}"
        if [ "$NGINX_ENABLED" = "1" ]; then
            nginx_enabled_value="true"
        else
            nginx_enabled_value="false"
        fi
    else
        reading "请输入服务端口 [8443]：" SERVER_PORT
        SERVER_PORT=${SERVER_PORT:-8443}

        reading "请输入API密钥 [随机生成]：" API_HASH
        if [ -z "$API_HASH" ]; then
            API_HASH=$(random_hex 16)
            ok "API密钥已生成: $API_HASH"
        fi

        reading "请输入管理员用户名 [admin]：" ADMIN_USER
        ADMIN_USER=${ADMIN_USER:-admin}

        reading "请输入管理员密码 [随机生成]：" ADMIN_PASS
        if [ -z "$ADMIN_PASS" ]; then
            ADMIN_PASS=$(random_hex 8)
            ok "管理员密码已生成: $ADMIN_PASS"
        fi

        reading "请输入流量采集间隔秒数 [20]：" TRAFFIC_INTERVAL
        TRAFFIC_INTERVAL=${TRAFFIC_INTERVAL:-20}

        reading "请输入流量批量更新数量 [10]：" TRAFFIC_BATCH_SIZE
        TRAFFIC_BATCH_SIZE=${TRAFFIC_BATCH_SIZE:-10}

        reading "请输入任务自动清理天数 [7]：" AUTO_CLEANUP_DAYS
        AUTO_CLEANUP_DAYS=${AUTO_CLEANUP_DAYS:-7}

        reading "是否启用 Nginx 反向代理插件？ y/n [n]：" nginx_enabled
        nginx_enabled=${nginx_enabled:-n}
        if [[ "$nginx_enabled" =~ ^[yY]$ ]]; then
            nginx_enabled_value="true"
        else
            nginx_enabled_value="false"
        fi
    fi

    SESSION_SECRET="$(random_hex 16)"

    if [ "$nginx_enabled_value" = "true" ]; then
        info "安装并启动 Nginx..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y nginx
        systemctl enable nginx >/dev/null 2>&1 || true
        systemctl restart nginx >/dev/null 2>&1 || true
        ok "Nginx 已安装并启动"
    fi

    info "写入配置文件..."
    sed -i "s|__SERVER_PORT__|$SERVER_PORT|g" "$config_file"
    sed -i "s|__API_HASH__|$(sed_escape "$API_HASH")|g" "$config_file"
    sed -i "s|__ADMIN_USER__|$(sed_escape "$ADMIN_USER")|g" "$config_file"
    sed -i "s|__ADMIN_PASS__|$(sed_escape "$ADMIN_PASS")|g" "$config_file"
    sed -i "s|__SESSION_SECRET__|$(sed_escape "$SESSION_SECRET")|g" "$config_file"
    sed -i "s|__TRAFFIC_INTERVAL__|$TRAFFIC_INTERVAL|g" "$config_file"
    sed -i "s|__TRAFFIC_BATCH_SIZE__|$TRAFFIC_BATCH_SIZE|g" "$config_file"
    sed -i "s|__AUTO_CLEANUP_DAYS__|$AUTO_CLEANUP_DAYS|g" "$config_file"
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

setup_systemd_service() {
    local service_file="/etc/systemd/system/lxdapi.service"

    if [ "$SKIP_SERVICE" = "1" ]; then
        warn "已跳过 systemd 服务安装"
        return
    fi

    if ! command -v systemctl >/dev/null 2>&1; then
        warn "未检测到 systemd，跳过服务安装"
        return
    fi

    info "配置 lxdapi 系统服务..."
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
    if ! systemctl restart lxdapi; then
        warn "lxdapi 服务启动失败，将在后面检查日志"
    else
        ok "lxdapi 服务已启动"
    fi
    ok "lxdapi 服务配置完成"
}

verify_backend() {
    local code
    local check_url="https://127.0.0.1:${SERVER_PORT}/api/system/containers"

    if [ "$SKIP_SERVICE" = "1" ] || ! command -v systemctl >/dev/null 2>&1; then
        info "服务未配置为 systemd，跳过连通性检查"
        return
    fi

    info "等待服务启动..."
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if systemctl is-active --quiet lxdapi; then
            break
        fi
        sleep 1
    done

    if ! systemctl is-active --quiet lxdapi; then
        warn "lxdapi 服务可能启动失败，查看日志: journalctl -u lxdapi -n 50 --no-pager"
        return
    fi

    for _ in 1 2 3 4 5; do
        code="$(curl -ksS -o /dev/null -w '%{http_code}' --max-time 10 -H "X-API-Hash: ${API_HASH}" "$check_url" 2>/dev/null || true)"
        if [ "$code" = "200" ]; then
            ok "后端接口连通性检查通过"
            return
        fi
        sleep 1
    done

    warn "后端服务已启动，但接口检查返回 $code"
}

write_summary() {
    local summary_file="/root/lxdapi-backend-install.info"
    local old_umask
    old_umask="$(umask)"
    umask 077

    cat > "$summary_file" <<EOF
LXD API 后端安装信息
安装目录: $INSTALL_DIR
程序路径: $INSTALL_DIR/lxdapi-$ARCH
服务端口: $SERVER_PORT
API密钥: $API_HASH
管理员用户: $ADMIN_USER
管理员密码: $ADMIN_PASS
数据库类型: sqlite
任务队列: memory
EOF
    chmod 600 "$summary_file"
    umask "$old_umask"
    ok "安装信息已保存: $summary_file"
}

main() {
    echo
    echo "========================================"
    echo "      LXD API 后端一键安装"
    echo "========================================"
    echo

    info "系统: $SYSTEM_ID"
    info "架构: $ARCH"
    check_install_dir

    prepare_system
    acquire_backend "${1:-}"

    if [ "$SKIP_LXD" != "1" ]; then
        install_lxd_backend
        init_lxd_network
    else
        info "已跳过 LXD 安装和初始化"
    fi

    deploy_backend
    configure_backend
    setup_systemd_service
    verify_backend
    write_summary

    echo
    echo "========================================"
    echo "        安装完成"
    echo "========================================"
    echo
    info "安装目录: $INSTALL_DIR"
    info "服务端口: $SERVER_PORT"
    info "API密钥: $API_HASH"
    info "管理员用户: $ADMIN_USER"
    info "管理员密码: $ADMIN_PASS"
    info "安装信息文件: /root/lxdapi-backend-install.info"
    echo
    if command -v systemctl >/dev/null 2>&1 && [ "$SKIP_SERVICE" != "1" ]; then
        systemctl status lxdapi --no-pager | head -n 8
        systemctl status lxdapi --no-pager | head -n 8 || true
    fi
}

main "${1:-}"
