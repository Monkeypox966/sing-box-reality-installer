# sing-box Reality Installer

在 **Alpine Linux / OpenRC** 服务器上安装 VLESS + Reality + Vision，并生成可导入 Mihomo / Clash Meta 的 YAML 节点。

<br>

## 第一步：准备服务器和端口

通过 SSH 登录 Alpine 服务器，并切换到 **root**。本脚本面向 Alpine / OpenRC，不能直接用于 Debian / Ubuntu。

选择一个可用 TCP 端口，例如下面使用的 **57111**。
在云平台安全组和服务器防火墙中放行该端口；NAT VPS 还需要提前设置端口映射。

脚本会安装依赖，并安装或替换本机名为 `sing-box` 的服务及其配置。
默认同时处理 IPv4 和 IPv6，有可用 IPv6 时会多生成一个节点。

<br>

## 第二步：下载并运行脚本

在服务器执行：

```sh
wget -O setup-sing-box.sh https://raw.githubusercontent.com/Monkeypox966/sing-box-reality-installer/main/setup-sing-box.sh && sh setup-sing-box.sh -p 57111
```

把 `57111` 换成选好的**服务器内部监听端口**。
`setup-sing-box.sh` 是独立脚本，无需下载其他项目文件。

如果已克隆完整仓库，也可以进入项目目录执行 `sh install.sh -p 57111`。
不传 `-p` 时，在交互终端中会提示输入端口。

<br>

## 第三步：复制节点到客户端

安装成功后，终端会打印 YAML，文件也保存在：

```sh
cat /etc/sing-box/client-info.txt
```

将输出合并到 Mihomo / Clash Meta 的客户端配置：

1. 已有 `proxies:` 时，只复制它下面的节点列表，粘贴到已有列表中，保持缩进。
2. 没有 `proxies:` 时，复制包含 `proxies:` 的完整节点片段。
3. 在客户端现有的代理组中选用或加入新节点，保存并重载配置，再测试连接。

输出是**节点配置片段**，完整客户端配置还需要自己的代理组和路由规则。
IPv4 与 IPv6 节点共用 UUID、Reality 参数和默认端口；使用其中可连接的节点即可。
无需配置其他可选参数就可以先测试默认安装。

<br>

## 第四步：确认服务与连接

在服务器检查：

```sh
rc-service sing-box status
```

确认服务已运行，再在客户端选中节点测试连接。安装器会添加 OpenRC 开机自启动。

如果服务器上有服务但客户端连不上，先检查服务商安全组、防火墙、NAT 映射和 YAML 中的连接地址及端口。
公网地址探测成功，只能证明出站网络可用，不能保证外部能连入。

<br>

## 日常操作

| 想做什么 | 命令 |
| --- | --- |
| 查看服务状态 | `rc-service sing-box status` |
| 重启服务 | `rc-service sing-box restart` |
| 停止服务 | `rc-service sing-box stop` |
| 启动服务 | `rc-service sing-box start` |
| 再次查看客户端节点 | `cat /etc/sing-box/client-info.txt` |
| 查看最近错误日志 | `tail -n 40 /var/log/sing-box-error.log` |
| 查看全部脚本选项 | `sh setup-sing-box.sh -h` |

停止服务不会取消开机自启动。重新运行安装脚本会生成新凭据，之后需要重新复制节点到客户端。

<br>

## 可选参数与 NAT 配置

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
sh setup-sing-box.sh -p 10000 -e 57111 -H 203.0.113.10

# IPv4 走 NAT 映射端口，原生 IPv6 直连内部监听端口
sh setup-sing-box.sh -p 10000 -e 57111 -E 10000 -H 203.0.113.10

# 仅 IPv4 / 仅 IPv6
sh setup-sing-box.sh -p 57111 -i 4
sh setup-sing-box.sh -p 57111 -i 6

# 指定 SNI 与版本
sh setup-sing-box.sh -p 57111 -s images.apple.com -v 1.14.4
```

默认仍使用 `-e` 作为所有节点的连接端口；若 NAT 映射仅作用于 IPv4，可用 `-E` 单独设置原生 IPv6 的端口。`-H` 指定 IPv4 时保留该地址并补充探测到的 IPv6；指定 IPv6 时保留该地址并补充 IPv4；指定域名时保留域名并补充 IPv6。单协议模式只输出该模式探测到的地址或显式指定的地址。

已指定的地址不会再次探测：例如 `-i 4 -H proxy.example.com` 不发公网探测请求；双栈模式指定 IPv4 时只探测 IPv6。HTTP 请求失败或返回的地址格式异常时，不采用该响应。端口会规范化为十进制，避免带前导零时生成无效 JSON。

<br>

## 常见问题

**NAT VPS 应该填哪个端口？** `-p` 填服务器内部监听端口，`-e` 填外部映射端口，
`-H` 填客户端连接的 IP 或域名。IPv6 不经 NAT 时，可用 `-E` 单独指定 IPv6 连接端口。

**没有 IPv6 可以用吗？** 可以。IPv6 不可用时，默认双栈模式只输出可用的 IPv4；
也可以显式使用 `-i 4`。纯 IPv6 服务器使用 `-i 6` 并确保客户端也能访问 IPv6。

**生成的地址是占位符？** 自动探测没有得到可用地址。用 `-H` 显式指定 IP 或域名后重新生成，
或手动替换客户端节点中的连接地址。

**提示安装锁被占用？** 先检查是否有另一个安装进程正在运行。
若先前安装被强制终止，确认锁目录 `/run/sing-box-setup.lock` 中记录的进程已结束后，再清理旧锁。

<br>

## 完整示例与实现细节（可选）

<details>
<summary>展开 YAML 示例、安装行为和开发测试</summary>

<br>

### 完整 YAML 示例与输出规则

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

<br>

### 低内存与安装行为

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

<br>

### 开发测试

运行时只依赖 Alpine 系统工具。Python / PyYAML 仅供开发测试；可用 uv 在隔离环境执行：

```sh
uv run --no-project --with PyYAML==6.0.3 python -m unittest discover -s tests -v
```

测试覆盖双栈、单栈、IPv6 独立端口、NAT 自定义地址、跳过多余探测、DNS/IP 格式、前导零、异常响应、JSON 元数据、镜像回退、安装锁、临时目录与失败回滚。元数据测试需要 `jq`。GitHub Actions 在 Alpine BusyBox ash 下执行同样测试，并用官方 sing-box 1.14.4 校验 IPv4、IPv6、默认双栈和双独立入站四种配置。回滚测试使用临时目录和模拟 OpenRC 命令，不安装或启动真实代理。

</details>

<br>

## 来源

项目基于用户提供的原始脚本修改，未整体复制其他安装器。开发前参考了 [SagerNet/sing-box](https://github.com/SagerNet/sing-box)、[eooce/Sing-box](https://github.com/eooce/Sing-box) 等已有实现，面向 Alpine / OpenRC 和低内存部署，当前默认支持 IPv4 / IPv6 双栈。

IPv4 / IPv6 的 YAML 增强之外，还添加了 Alpine 前置检查，并删除了未被路由使用的旧 `block` 出站，避免新版 sing-box 对旧类型的兼容问题。仓库不含真实服务器配置、生成的私钥或连接凭据。
