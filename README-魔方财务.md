# 魔方财务对接指南

本项目包含两部分：

- `lxdapi/`：Go 编写的 LXD API 服务器，提供容器生命周期、IPv4/IPv6、端口映射、流量、控制台、管理面板等 REST API。
- `Fmis/zjmf/lxdapiserver/`：魔方财务服务器模块插件，负责把魔方财务的自动开通、暂停、续费、重装、状态同步等动作转发给 LXD API 服务器。

## 1. 安装 LXD 环境

推荐在 Debian 或 Ubuntu 的 root 环境执行：

```bash
apt update && apt install sudo wget curl nftables -y
bash <(curl -Ls https://raw.githubusercontent.com/ccmaoxiong/lxdapi-web-server/main-stable/Shell/lxd_install.sh)
```

LXD 初始化后，建议按实际磁盘情况创建 ZFS 或 Btrfs 存储池，并导入 Debian、Ubuntu、Alpine 等镜像。仓库内 `Shell/` 提供对应脚本。

### 一键安装 LXD API 后端

如果不需要分步执行，也可以直接运行后端一键安装脚本。它会一次完成基础软件包、LXD、后端程序、配置文件、systemd 服务和连通性检查：

```bash
sudo bash Shell/lxdapi_onekey_install.sh
```

免交互安装时可使用环境变量：

```bash
AUTO_INSTALL=1 \
SERVER_PORT=8443 \
API_HASH=你的API密钥 \
ADMIN_USER=admin \
ADMIN_PASS=你的密码 \
sudo bash Shell/lxdapi_onekey_install.sh
```

LXD 网络默认会初始化 `lxdbr0`，网段为 `10.66.0.1/16` + `fd66:6666::1/64`，并开启 IPv4/IPv6 NAT。需要自定义时，在免交互安装前传入环境变量：

```bash
AUTO_INSTALL=1 \
LXD_NETWORK_NAME=lxdbr0 \
LXD_IPV4_ADDRESS=10.66.0.1/16 \
LXD_IPV4_NAT=true \
LXD_IPV6_ADDRESS=none \
LXD_IPV6_NAT=false \
sudo bash Shell/lxdapi_onekey_install.sh
```

只禁用 IPv6 时可用 `LXD_IPV6_ADDRESS=none LXD_IPV6_NAT=false`。如果 LXD 的 `lxdbr0` 已经存在，脚本默认不修改现有网络；需要按新参数覆盖更新时追加 `LXD_NETWORK_FORCE=1`。

LXD 已经装好时，可以只安装后端：

```bash
SKIP_LXD=1 sudo bash Shell/lxdapi_onekey_install.sh
```

安装完成后，API Hash、管理员账号和密码会保存在 `/root/lxdapi-backend-install.info`。

如果 LXD 安装时出现 `context canceled`，通常是 snapd 刷新任务中断或网络超时。手动恢复：

```bash
snap changes
snap abort <任务ID>
systemctl restart snapd
snap install lxd --channel=latest/stable
```

如果还在报 `assumes unsupported features: snapd2.75`，说明 snapd 太旧，先刷新 snapd：

```bash
snap refresh snapd --channel=latest/stable
systemctl restart snapd
snap version
snap install lxd --channel=latest/stable
```

网络需要代理时，可以给一键脚本传入 snap 代理：

```bash
SNAP_PROXY_HTTP=http://127.0.0.1:7890 \
SNAP_PROXY_HTTPS=http://127.0.0.1:7890 \
sudo bash Shell/lxdapi_onekey_install.sh
```

### 云端一键安装

云端安装不依赖服务器上的源码或本地编译文件，脚本会直接下载 GitHub 或 Gitee Release 中的安装包，并执行包内的 `install-backend.sh`。

GitHub：

```bash
bash <(curl -Ls https://raw.githubusercontent.com/ccmaoxiong/lxdapi-web-server/main-stable/Shell/lxdapi_cloud_install.sh)
```

Gitee：

```bash
RELEASE_SOURCE=gitee bash <(curl -Ls https://gitee.com/ccmaoxiong/lxdapi-web-server/raw/main-stable/Shell/lxdapi_cloud_install.sh)
```

指定 Release 版本：

```bash
LXDAPI_TAG=v1.0.0 bash <(curl -Ls https://raw.githubusercontent.com/ccmaoxiong/lxdapi-web-server/main-stable/Shell/lxdapi_cloud_install.sh)
```

指定安装包直链：

```bash
LXDAPI_RELEASE_URL=https://example.com/lxdapi-linux-amd64.tar.gz bash <(curl -Ls https://raw.githubusercontent.com/ccmaoxiong/lxdapi-web-server/main-stable/Shell/lxdapi_cloud_install.sh)
```

云端脚本默认使用 `AUTO_INSTALL=1`，会自动生成 API Hash 和管理员密码，并保存到 `/root/lxdapi-backend-install.info`。端口、账号、代理等参数仍可通过环境变量覆盖。

## 2. 编译并配置 LXD API 服务器

在 Linux 上执行：

```bash
cd lxdapi
chmod +x build.sh
./build.sh
```

如果系统没有 Go，`build.sh` 会自动下载官方 Go 1.24.10。默认安装到 `/usr/local/go`；当前用户没有写权限时会安装到 `~/.local/go`。也可通过环境变量覆盖：

```bash
GO_VERSION=1.24.10 GO_INSTALL_DIR=/opt/go ./build.sh
```

如果下载超时，可以指定国内镜像：

```bash
DOWNLOAD_BASE=https://mirrors.aliyun.com/golang/ ./build.sh
```

脚本会生成 `lxdapi-amd64` 或 `lxdapi-arm64`，并打包到 `lxdapi/release/`。编辑 `configs/config.yaml` 时至少需要设置：

- `system.server.port`：对外提供服务端口，默认安装脚本使用 `8443`。
- `system.security.api_hash`：魔方财务接口配置中的 Hash，必须保持机密。
- `admin.username` 和 `admin.password`：后台登录账号。
- `lxc.socket`：LXD 的 Unix socket，默认 `"/var/snap/lxd/common/lxd/unix.socket"`。
- `traffic.enabled`：按需开启流量监控。

编译完成后，可以用本地安装脚本直接部署到 `/opt/lxdapi` 并创建 systemd 服务：

```bash
bash Shell/lxdapi_install_local.sh
```

非默认目录或跳过系统服务时可使用：

```bash
LXDAPI_INSTALL_DIR=/opt/lxdapi SKIP_SERVICE=1 bash Shell/lxdapi_install_local.sh
```

`build.sh` 生成的 `release/*.tar.gz` 安装包内也已包含 `install.sh`。解压发布包后可以直接安装：

```bash
tar -xzf lxdapi-linux-amd64.tar.gz
cd lxdapi-amd64
sudo bash install.sh
```

发布包内还包含 `install-backend.sh`，可用它同时安装后端和 LXD：

```bash
sudo bash install-backend.sh
```

默认服务使用 HTTPS 和自签名证书，证书不存在时会自动生成。

启动验证：

```bash
./lxdapi-amd64
```

接口连通性测试：

```bash
curl -k https://127.0.0.1:8443/api/system/containers \
  -H "X-API-Hash: 你的API密钥"
```

## 3. 安装魔方财务插件

把 `Fmis/zjmf/lxdapiserver/` 整个目录上传到魔方财务服务器的：

```text
/public/plugins/servers/lxdapiserver
```

进入魔方财务后台的 `设置 > 通用接口 > 接口`，新增服务器接口：

| 配置项 | 值 |
| --- | --- |
| 名称 | 按需填写 |
| IP地址 | LXD API 服务器 IP 或域名 |
| 服务器模块 | `魔方财务-LXD对接插件 by xkatld` |
| 端口 | LXD API 服务器端口 |
| secure | 按服务端 TLS 配置开启或关闭 |
| Hash | `config.yaml` 中的 `system.security.api_hash` |

插件会读取魔方财务传入的 `secure` 配置自动选择 `https://` 或 `http://`，默认按 HTTPS 处理。

## 4. 配置产品

在商品编辑页选择 `自动开通 > 自动化接口`，并绑定上面创建的接口。然后在产品配置中新增配置项：

| 配置项 | 对应 `configoptions` key | 后端单位 |
| --- | --- | --- |
| CPU核心数 | `cpus` | 核 |
| 内存 | `memory` | MB |
| 硬盘 | `disk` | MB |
| 月流量限制 | `traffic_limit` | GB |
| 入站带宽 | `ingress` | Mbit |
| 出站带宽 | `egress` | Mbit |
| 操作系统 | `image` | LXD 镜像别名 |
| 独立IPv4数量 | `ipv4_pool_limit` | 个 |
| IPv4转发规则数量 | `ipv4_mapping_limit` | 条 |
| 独立IPv6数量 | `ipv6_pool_limit` | 个 |
| IPv6转发规则数量 | `ipv6_mapping_limit` | 条 |
| 反代理规则数量 | `reverse_proxy_limit` | 条 |

插件支持带单位的配置值，例如 `512MB`、`1GB`、`100Mbps`，会在发送给后端前转换为 MB、GB、Mbit 数值。

## 5. 已对接的财务动作

| 魔方财务动作 | API 调用 |
| --- | --- |
| 接口测试 | `GET /api/system/containers` |
| 开通/创建容器 | `POST /api/system/containers` |
| 删除/销户 | `DELETE /api/system/containers/{name}` |
| 开机 | `POST /api/system/containers/{name}/action?action=start` |
| 关机 | `POST /api/system/containers/{name}/action?action=stop` |
| 重启 | `POST /api/system/containers/{name}/action?action=restart` |
| 暂停 | `POST /api/system/containers/{name}/action?action=pause` |
| 恢复 | `POST /api/system/containers/{name}/action?action=resume` |
| 重装 | `POST /api/system/containers/{name}/action?action=reinstall` |
| 状态同步 | `GET /api/system/containers/{name}` |
| 重置密码 | `POST /api/system/containers/{name}/action?action=reset-password` |
| 重置流量 | `POST /api/system/traffic/reset?name={name}` |
| 容器面板 | `GET /api/system/containers/{name}/credential` |

完整的 Swagger 文档可通过 `/swagger/index.html` 查看。
