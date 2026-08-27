#!/bin/bash

set -euo pipefail

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

GITHUB_OWNER="${GITHUB_OWNER:-ccmaoxiong}"
GITHUB_REPO="${GITHUB_REPO:-lxd}"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
GITEE_OWNER="${GITEE_OWNER:-ccmaoxiong}"
GITEE_REPO="${GITEE_REPO:-lxd}"

if [ "$(id -u)" -ne 0 ]; then
    err "请使用 root 运行，或使用 sudo bash $0"
fi

if ! command -v tar >/dev/null 2>&1; then
    info "安装 tar..."
    DEBIAN_FRONTEND=noninteractive apt-get update >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y tar
fi

if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    info "安装 curl..."
    DEBIAN_FRONTEND=noninteractive apt-get update >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl
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

TEMP_DIR="$(mktemp -d)"
cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

download_file() {
    local file="$1"
    local url="$2"

    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 3 --connect-timeout 20 -m 300 -o "$file" "$url"
    else
        wget -O "$file" "$url"
    fi
}

resolve_release_url() {
    local api_url
    local base_url
    local tag

    if [ -n "${LXDAPI_RELEASE_URL:-}" ]; then
        RELEASE_URL="$LXDAPI_RELEASE_URL"
        return
    fi

    case "${RELEASE_SOURCE:-github}" in
        github)
            api_url="https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/releases/latest"
            base_url="https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/releases/download"
            ;;
        gitee)
            api_url="https://gitee.com/api/v5/repos/${GITEE_OWNER}/${GITEE_REPO}/releases/latest"
            base_url="https://gitee.com/${GITEE_OWNER}/${GITEE_REPO}/releases/download"
            ;;
        *)
            err "RELEASE_SOURCE 仅支持 github 或 gitee"
            ;;
    esac

    tag="${LXDAPI_TAG:-}"
    if [ -z "$tag" ]; then
        if command -v curl >/dev/null 2>&1; then
            tag="$(curl -fsSL --connect-timeout 20 "$api_url" 2>/dev/null | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1 || true)"
        else
            tag="$(wget -qO- "$api_url" 2>/dev/null | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1 || true)"
        fi
    fi

    if [ -z "$tag" ]; then
        err "无法获取最新版本，请设置 LXDAPI_TAG 或 LXDAPI_RELEASE_URL"
    fi

    RELEASE_URL="${base_url}/${tag}/lxdapi-linux-${ARCH}.tar.gz"
    info "最新版本: $tag"
}

download_release() {
    local archive="$TEMP_DIR/lxdapi.tar.gz"

    info "正在下载 LXD API 发布包..."
    info "下载地址: $RELEASE_URL"
    download_file "$archive" "$RELEASE_URL"

    if [ ! -s "$archive" ]; then
        err "下载失败或文件为空"
    fi

    mkdir -p "$TEMP_DIR/lxdapi"
    tar -xzf "$archive" -C "$TEMP_DIR/lxdapi" --strip-components=1
    rm -f "$archive"

    if [ ! -f "$TEMP_DIR/lxdapi/lxdapi-$ARCH" ] || [ ! -d "$TEMP_DIR/lxdapi/configs" ]; then
        err "发布包内容不完整或架构不匹配"
    fi
    ok "发布包下载并解压完成"
}

fetch_onekey_installer() {
    local url

    if [ -n "${LXDAPI_ONEKEY_URL:-}" ]; then
        url="$LXDAPI_ONEKEY_URL"
    elif [ "${RELEASE_SOURCE:-github}" = "gitee" ]; then
        url="https://gitee.com/${GITEE_OWNER}/${GITEE_REPO}/raw/${GITHUB_BRANCH}/Shell/lxdapi_onekey_install.sh"
    else
        url="https://raw.githubusercontent.com/${GITHUB_OWNER}/${GITHUB_REPO}/${GITHUB_BRANCH}/Shell/lxdapi_onekey_install.sh"
    fi

    info "下载云端安装器: $url"
    download_file "$TEMP_DIR/lxdapi_onekey_install.sh" "$url"
}

main() {
    echo
    echo "========================================"
    echo "     LXD API 云端一键安装"
    echo "========================================"
    echo

    info "系统架构: $ARCH"
    resolve_release_url
    download_release

    AUTO_INSTALL="${AUTO_INSTALL:-1}"
    export AUTO_INSTALL

    info "开始执行云端安装..."
    if [ -f "$TEMP_DIR/lxdapi/install-backend.sh" ]; then
        INSTALLER="$TEMP_DIR/lxdapi/install-backend.sh"
    else
        warn "发布包未包含 install-backend.sh，自动获取云端安装器"
        fetch_onekey_installer
        INSTALLER="$TEMP_DIR/lxdapi_onekey_install.sh"
        LXDAPI_SOURCE_DIR="$TEMP_DIR/lxdapi"
        export LXDAPI_SOURCE_DIR
    fi

    chmod +x "$INSTALLER"
    if ! bash "$INSTALLER"; then
        err "云端安装失败"
    fi
}

main
