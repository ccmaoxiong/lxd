#!/bin/bash

set -euo pipefail

GO_VERSION="${GO_VERSION:-1.24.10}"
DOWNLOAD_BASE="${DOWNLOAD_BASE:-https://go.dev/dl}"

log() { echo "[go-install] $1"; }
warn() { echo "[go-install][warn] $1"; }

case "$(uname -m)" in
    x86_64|amd64)
        GO_ARCH="amd64"
        ;;
    aarch64|arm64)
        GO_ARCH="arm64"
        ;;
    *)
        log "错误: 不支持的架构: $(uname -m)"
        exit 1
        ;;
esac

if [ -n "${GO_INSTALL_DIR:-}" ]; then
    INSTALL_DIR="$GO_INSTALL_DIR"
elif [ -w /usr/local ]; then
    INSTALL_DIR="/usr/local/go"
else
    INSTALL_DIR="$HOME/.local/go"
fi

if [ "$INSTALL_DIR" = "/" ] || [ "$INSTALL_DIR" = "/usr" ] || [ "$INSTALL_DIR" = "$HOME" ]; then
    log "错误: GO_INSTALL_DIR 不允许设置为 $INSTALL_DIR"
    exit 1
fi

if [ -x "$INSTALL_DIR/bin/go" ] && "$INSTALL_DIR/bin/go" version 2>/dev/null | grep -q "go${GO_VERSION}"; then
    log "已存在 Go ${GO_VERSION}: $INSTALL_DIR"
    echo "$INSTALL_DIR/bin"
    exit 0
fi

if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    log "错误: 未找到 curl 或 wget，无法下载 Go"
    exit 1
fi

if ! command -v tar >/dev/null 2>&1; then
    log "错误: 未找到 tar 命令"
    exit 1
fi

archive="go${GO_VERSION}.linux-${GO_ARCH}.tar.gz"
url="${DOWNLOAD_BASE}/${archive}"
tmp_file="$(mktemp)"

log "检测到架构: ${GO_ARCH}"
log "安装目录: ${INSTALL_DIR}"
log "下载 Go ${GO_VERSION}: ${url}"

trap 'rm -rf "$tmp_file"' EXIT

download_go() {
    local download_url="$1"
    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 3 --connect-timeout 20 -o "$tmp_file" "$download_url"
    else
        wget -O "$tmp_file" "$download_url"
    fi
}

if ! download_go "$url"; then
    if [ "$DOWNLOAD_BASE" = "https://go.dev/dl" ]; then
        mirror_url="https://mirrors.aliyun.com/golang/${archive}"
        warn "官方源下载失败，尝试国内镜像：$mirror_url"
        if ! download_go "$mirror_url"; then
            log "错误: Go 下载失败"
            exit 1
        fi
    else
        log "错误: Go 下载失败"
        exit 1
    fi
fi

parent_dir="$(dirname "$INSTALL_DIR")"
if [ ! -d "$parent_dir" ]; then
    mkdir -p "$parent_dir"
fi

if [ -e "$INSTALL_DIR" ]; then
    rm -rf "$INSTALL_DIR"
fi

tar -C "$parent_dir" -xzf "$tmp_file"

if [ ! -x "$INSTALL_DIR/bin/go" ]; then
    log "错误: Go 安装失败，未找到 $INSTALL_DIR/bin/go"
    exit 1
fi

log "Go ${GO_VERSION} 安装完成"
"$INSTALL_DIR/bin/go" version
echo "$INSTALL_DIR/bin"
