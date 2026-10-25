# sing-box Reality Installer

基于现有 `setup-sing-box.sh` 整理的 **Alpine Linux / OpenRC** 一键脚本项目，安装 sing-box 的 **VLESS + Reality + Vision** 服务，并打印可导入 Mihomo / Clash Meta 的 YAML 节点。

默认双栈模式下，分别探测公网 IPv4 与 IPv6；有可用 IPv6 时输出两个独立节点，共用端口、UUID 和 Reality 参数。IPv6 不可用时只输出 IPv4，纯 IPv6 主机则输出 IPv6。

## 一键安装

仓库已公开，无需 GitHub 登录。在 Alpine 服务器上以 root 下载独立脚本并执行：

```sh
wget -O setup-sing-box.sh https://raw.githubusercontent.com/Monkeypox966/sing-box-reality-installer/main/setup-sing-box.sh && sh setup-sing-box.sh -p 57111
```

如果已经下载或克隆完整项目，进入源码目录后执行：

```sh
sh install.sh -p 57111
```

已安装 Git 时，也可以直接克隆公开仓库：

```sh
git clone https://github.com/Monkeypox966/sing-box-reality-installer.git
cd sing-box-reality-installer
sh install.sh -p 57111
```

也可以将项目目录或单独的 `setup-sing-box.sh` 上传到服务器，直接运行：

```sh
sh setup-sing-box.sh -p 57111
```

`setup-sing-box.sh` 是独立脚本，不依赖仓库内其他文件。不带 `-p` 时，如果连接的是交互终端，会提示输入监听端口。

> 只支持 Alpine Linux 和 OpenRC。脚本会安装依赖，并安装或替换本机的 `sing-box` 配置和同名服务；重复运行会生成新凭据。它不会操作其他名称的代理服务，也不会替你修改防火墙或 NAT 映射。

## 参数

| 参数 | 含义 | 默认值 |
|---|---|---|
| `-p` | 服务器内部监听端口，必填或交互输入 | 无 |
| `-e` | YAML 中的客户端连接端口 | 与 `-p` 相同 |
| `-E` | 单独指定 IPv6 节点的连接端口 | 与 `-e` 相同 |
| `-H` | 自定义客户端连接 IP 或域名，适用于 NAT VPS | 自动探测 |
| `-i` | 监听模式：`4`、`6`、`dual` | `dual` |
| `-s` | Reality SNI 域名 | `images.apple.com` |
| `-d` | DNS 服务器 IP，支持 IPv4 / IPv6 | 按监听模式选择 |
| `-v` | sing-box 版本，不带开头的 `v` | `latest` |
| `-S` | 指定安装包 SHA-256 | 尝试从官方 GitHub API 读取 |
| `-P` | 官方下载失败时允许第三方镜像，需要 SHA-256 | 关闭 |
| `-h` | 查看帮助 | — |

```sh
# NAT 示例：内部端口 10000，映射端口 57111
sh install.sh -p 10000 -e 57111 -H 203.0.113.10

# IPv4 走 NAT 映射端口，原生 IPv6 直连内部监听端口
sh install.sh -p 10000 -e 57111 -E 10000 -H 203.0.113.10

# 仅 IPv4 / 仅 IPv6
sh install.sh -p 57111 -i 4
sh install.sh -p 57111 -i 6

# 指定 SNI 与版本
sh install.sh -p 57111 -s images.apple.com -v 1.14.4
```

默认仍使用 `-e` 作为所有节点的连接端口；若 NAT 映射仅作用于 IPv4，可用 `-E` 单独设置原生 IPv6 的端口。`-H` 指定 IPv4 时保留该地址并补充探测到的 IPv6；指定 IPv6 时保留该地址并补充 IPv4；指定域名时保留域名并补充 IPv6。单协议模式只输出该模式探测到的地址或显式指定的地址。

已指定的地址不会再次探测：例如 `-i 4 -H proxy.example.com` 不发公网探测请求；双栈模式指定 IPv4 时只探测 IPv6。HTTP 请求失败或返回的地址格式异常时，不采用该响应。端口会规范化为十进制，避免带前导零时生成无效 JSON。

## YAML 输出

最终配置保存到 `/etc/sing-box/client-info.txt`，同时打印到终端。例如：

```yaml
proxies:
  - name: "reality-ipv4"
    type: vless
    server: "203.0.113.10"
    port: 57111
    uuid: "11111111-1111-4111-8111-111111111111"
    udp: true
    tls: true
    flow: xtls-rprx-vision
    servername: "images.apple.com"
    reality-opts:
      public-key: "<generated-public-key>"
      short-id: "0012"
    client-fingerprint: chrome
  - name: "reality-ipv6"
    type: vless
    server: "2001:db8::10"
    port: 57111
    uuid: "11111111-1111-4111-8111-111111111111"
    udp: true
    tls: true
    flow: xtls-rprx-vision
    servername: "images.apple.com"
    reality-opts:
      public-key: "<generated-public-key>"
      short-id: "0012"
    client-fingerprint: chrome
```

上面的地址和凭据仅作格式演示。IPv6 在 YAML 中是普通字符串，使用引号，不写成 `[IPv6地址]`；`short-id` 也始终保留为字符串，避免前导零丢失。

如果现有配置已经有 `proxies:`，只复制下面的节点列表。公网探测使用强制 IPv4 / IPv6 的 HTTPS 请求；IPv6 回环、链路本地、ULA、组播或异常响应不会作为自动节点输出。探测成功代表有该协议的出站连通性，不能代替入站端口、防火墙和 NAT 检查。

默认 `dual` 监听 `::`。若系统设置 `net.ipv6.bindv6only=1`，脚本会另外添加 `0.0.0.0` 入站，使 IPv4 也能连接，两个入站共用凭据。主机完全禁用 IPv6 时，默认双栈模式退回 IPv4；显式要求 `-i 6` 时直接报告错误。本项目不修改 sysctl 或防火墙。全部地址探测失败时，输出带明显占位符的节点，使用 `-H` 指定地址或手动替换。

## 低内存与安装行为

保留原脚本的磁盘临时目录策略、Go 内存目标和服务启动失败回滚：

- 默认 `GOMEMLIMIT=64MiB`、`GOGC=50`；自定义的 `SING_BOX_GOMEMLIMIT` 和 `SING_BOX_GOGC` 会写入生成的服务默认值，重启后继续生效。Go 内存目标不是操作系统强制上限。
- 临时目录优先放在 `/root` 或 `/var/tmp` 的磁盘文件系统中；默认要求约 180 MB 可用空间。
- 新配置先由新二进制执行 `sing-box check`，成功后再替换原有文件。
- 原有二进制、服务器配置、客户端 YAML 和 OpenRC 脚本会保留带时间戳的备份。替换文件后发生可捕获错误或中断时，会停止本项目服务，以原子替换方式恢复旧文件，再按原有运行状态恢复服务；首次安装失败时清除新文件和新加的自启动项。旧错误日志不会被清空。
- 下载包和解压目录自动清理。为支持回滚，历史备份不会自动删除。
- sing-box 仍由 OpenRC 管理，服务名为 `sing-box`。
- 使用 `/run/sing-box-setup.lock` 阻止同时安装，正常退出会清理锁。强制终止或断电无法执行回滚；若留下锁目录，先检查其中的 `pid` 并确认安装进程已结束，再清理旧锁。

安装时会增加轻量的 `jq` 依赖，用于精确读取 GitHub JSON 元数据，避免因字段顺序、压缩格式或近似文件名选错 SHA-256。它不参与代理服务的日常运行。官方 API 不可用时回退到已验证的 sing-box 1.14.4；第三方镜像下载仍要求提供可信 SHA-256。

```sh
rc-service sing-box status
rc-service sing-box restart
cat /etc/sing-box/client-info.txt
tail -n 40 /var/log/sing-box-error.log
```

环境变量详细选项见 `sh install.sh -h`。

## 测试

运行时只依赖 Alpine 系统工具。Python / PyYAML 仅供开发测试；可用 uv 在隔离环境执行：

```sh
uv run --no-project --with PyYAML==6.0.3 python -m unittest discover -s tests -v
```

测试覆盖双栈、单栈、IPv6 独立端口、NAT 自定义地址、跳过多余探测、DNS/IP 格式、前导零、异常响应、JSON 元数据、镜像回退、安装锁、临时目录与失败回滚。元数据测试需要 `jq`。GitHub Actions 在 Alpine BusyBox ash 下执行同样测试，并用官方 sing-box 1.14.4 校验 IPv4、IPv6、默认双栈和双独立入站四种配置。回滚测试使用临时目录和模拟 OpenRC 命令，不安装或启动真实代理。

## 来源

项目基于用户提供的原始脚本修改，未整体复制其他安装器。开发前参考了 [SagerNet/sing-box](https://github.com/SagerNet/sing-box)、[eooce/Sing-box](https://github.com/eooce/Sing-box) 等已有实现，面向 Alpine / OpenRC 和低内存部署，当前默认支持 IPv4 / IPv6 双栈。

IPv4 / IPv6 的 YAML 增强之外，还添加了 Alpine 前置检查，并删除了未被路由使用的旧 `block` 出站，避免新版 sing-box 对旧类型的兼容问题。仓库不含真实服务器配置、生成的私钥或连接凭据。
