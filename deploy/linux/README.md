# Remnawave Node · Linux 一键部署（无 Docker）

直接在 Linux 上运行 Remnawave Node，不需要 Docker：LXC 容器（Proxmox、Incus）、VPS、虚拟机都可以。
功能与官方 Docker 镜像一致，面板看到的是同一个节点：所有接口、插件（nftables、torrent blocker、断连）、自定义内核、geodata 都保留。

## 支持的系统

| 系统 | 实测版本（Proxmox 官方 LXC 模板） | 其他版本 |
|---|---|---|
| Debian | 12、13 | 10、11 理论可用（glibc ≥ 2.28），未实测 |
| Ubuntu | 22.04、24.04 | 20.04、26.04 理论可用，未实测 |
| Rocky / Alma / CentOS Stream / RHEL | Rocky 9 | 8、10 理论可用，未实测 |
| Alpine | 3.22、3.24 | 3.23+ 使用系统自带的 Node.js；3.22 及更早只支持 x86_64 |
| 其他 glibc ≥ 2.28 且使用 systemd 的发行版 | — | 尽量兼容，未实测 |

CPU 架构：x86_64、aarch64。

## 一键安装

```sh
wget -qO- https://github.com/besire/node/releases/latest/download/install.sh | sh
```

没有 wget 的系统（如 Rocky）用 curl：

```sh
curl -fsSL https://github.com/besire/node/releases/latest/download/install.sh | sh
```

会打开管理面板：选 `1`，输入节点端口，粘贴面板中的 SECRET_KEY（可以直接粘贴 `SECRET_KEY="..."` 整行），完成。
安装后随时输入 `rwnode` 打开面板。

无人值守安装（脚本、批量部署），传入 `--secret-key` 后全程不提问：

```sh
wget -qO- https://github.com/besire/node/releases/latest/download/install.sh | sh -s -- install --port 2222 --secret-key '面板里的 SECRET_KEY'
```

安装过程不依赖发行版的包管理器：下载用系统自带的 wget/curl，Xray 的 zip、ASN 库的 zstd 由 Node.js 解压，Debian/Ubuntu 上不会执行 `apt-get update`。只有缺少 wget/curl、证书或 logrotate 时才会调用包管理器安装。

## 管理面板 rwnode

```
  Remnawave Node 管理面板  rwnode
  ------------------------------------------------------
  系统   Debian GNU/Linux 13 (trixie) · x64 · systemd
  状态   ● 运行中
  版本   节点 3.4.1 · Xray 26.6.27 · 端口 2222
  内存   节点 43 MB · Xray 10 MB（私有内存）
  ------------------------------------------------------
   1  安装 / 重装
   2  更新（节点程序、Xray、数据文件）
   3  卸载

   4  启动
   5  停止
   6  重启

   7  修改端口
   8  修改 SECRET_KEY
   9  切换 Xray 版本

  10  查看节点日志
  11  查看 Xray 日志
  12  导出当前 Xray 配置

   0  退出
```

所有功能也可以用命令完成，`rwnode help` 查看全部：

| 命令 | 作用 |
|---|---|
| `rwnode` | 打开管理面板 |
| `rwnode install` / `update` / `uninstall [--purge]` | 安装 / 更新 / 卸载 |
| `rwnode start` / `stop` / `restart` / `status` | 服务控制和状态 |
| `rwnode port 3333` | 修改节点端口并重启（面板里的节点端口要改成一致） |
| `rwnode key '<SECRET_KEY>'` | 更换 SECRET_KEY 并重启 |
| `rwnode xray 26.9.9` / `rwnode xray default` | 切换 Xray 版本（需要 26.5.3 或更高）/ 恢复默认版本（26.6.27） |
| `rwnode log` / `rwnode xlog` | 实时查看节点 / Xray 日志 |
| `rwnode dump` | 导出当前 Xray 配置到 `/root/rwnode-xray-config.json`（600 权限） |

名字用 `rwnode` 而不是 `rmnode`：`rm` 开头容易看成“删除”，`rw` 是上游自己用的缩写（进程名 `rw-node`、内核 `rw-core`）。

## 资源占用

实测（x86_64，Proxmox Debian 13 / Alpine 3.24 模板）：

| 组件 | Debian / Ubuntu / RHEL | Alpine 3.23+ |
|---|---|---|
| 节点程序 `/opt/remnanode` | 8 MB | 8 MB |
| Node.js 24 运行时 | 104 MB（`/usr/local/lib/remnanode`，精简版） | 使用系统 nodejs 包 |
| Xray + geoip/geosite | 36 + 27 MB | 36 + 27 MB |
| ASN 数据库（可选） | 12 MB | 12 MB |
| geocheck（可选） | 9 MB | 9 MB |

安装时可以跳过可选组件（面板里回答 n，或 `--no-asn --no-geocheck`）。

内存：见下文「内存」一节。

## 为什么还需要 Node.js 24

节点程序本身是用 TypeScript（NestJS）写的，Node.js 是它的运行环境，不装 Node.js 就只能整个用别的语言重写。
依赖里的原生模块（nftables、断连、zstd 解压）要求 Node.js 24。

- Alpine 3.23+ 直接使用系统的 `nodejs` 包。
- 其他系统的官方源里 Node.js 都低于 24（Debian 13 是 20，Ubuntu 26.04 是 22），rwnode 会安装一份独立的 Node.js 24 到 `/usr/local/lib/remnanode`：去掉了调试符号（比官方包小 17 MB），不进 PATH，不影响系统里其他 Node.js。

## 内存

节点进程的默认参数已经调过（`remnanode-start`）：V8 新生代缩小到 2 MB、`--optimize-for-size`、glibc `MALLOC_ARENA_MAX=2`，另外 JS 依赖打包压缩进了 `main.js`。

实测 Debian 13 x64，节点进程自身占用的内存（RssAnon，不含映射的 Node.js 程序文件）：

| | 空闲 | 5000 用户 | 20000 用户 | 下发 20000 用户耗时 |
|---|---|---|---|---|
| 上游原样（未打包，V8 默认参数） | 60 MB | 66 MB | 77 MB | 1398 ms |
| 打包，V8 默认参数 | 54 MB | 61 MB | 63 MB | 1390 ms |
| **rwnode 默认**（打包 + 调优参数） | **39 MB** | **43 MB** | **46 MB** | 1404 ms |

Alpine 3.24（系统 Node.js 24.18）：打包 + V8 默认参数 52 / 60 / 64 MB，rwnode 默认 **38 / 42 / 43 MB**。

另有最多约 70 MB 是映射进内存的 Node.js 程序文件（RssFile），属于可回收、可共享的页缓存，内存紧张时内核会先回收它，`top` 里的 RES 会把它算进去。Xray 自身在 20000 用户时约 22 MB。

内存特别小的 VPS 可以在 `/etc/remnanode/remnanode.env` 里限制 JS 堆，然后 `rwnode restart`：

```sh
NODE_MAX_HEAP_MB=192
```

限制过低时，用户很多的节点在面板下发配置时会因内存不足退出（服务会自动重启），请按用户规模留出余量。

## Proxmox LXC 建议

- 非特权容器即可，**不需要开 nesting**。
- 文件句柄上限：非特权容器的上限由宿主决定，节点启动时会自动取可用的最大值。需要更高时在宿主的 `/etc/pve/lxc/<id>.conf` 加一行 `lxc.prlimit.nofile: 1048576`，然后重启容器。
- nftables 类插件（入站/出站过滤、torrent blocker）使用容器自己的网络命名空间，需要宿主内核支持 nf_tables（PVE 默认内核支持）。
- 断连功能依赖宿主内核的 `CONFIG_INET_DIAG_DESTROY`，可在宿主上执行 `grep INET_DIAG_DESTROY /boot/config-$(uname -r)` 确认。
- 容器在 NAT 后面时，要把节点端口和 Xray 入站端口都转发进来。

## 文件位置

| 路径 | 内容 |
|---|---|
| `/etc/remnanode/remnanode.env` | 配置（端口、SECRET_KEY 等，600 权限） |
| `/opt/remnanode` | 节点程序 |
| `/usr/local/lib/remnanode/node` | Node.js 运行时（非 Alpine） |
| `/usr/local/bin/rwnode` | 管理工具 |
| `/usr/local/bin/xray`、`/usr/local/share/xray` | Xray 和 geo 数据 |
| `/var/log/remnanode/node.log`、`/var/log/xray/current` | 日志（自动轮转，各约 10 MB 上限） |
| `/etc/systemd/system/remnanode.service` 或 `/etc/init.d/remnanode` | 服务 |

## 从 3.4.1-alpine.1 升级

旧版安装脚本没有 `rwnode`，执行一次新脚本的 update 即可：

```sh
wget -qO- https://github.com/besire/node/releases/latest/download/install.sh | sh -s -- update
```

## 构建与发布

推一个 tag，`.github/workflows/build-linux.yml` 会在 x64 和 arm64 runner 上构建，并附加到 GitHub Release：

```
remnanode-glibc-{x64,arm64}.tar.gz          节点程序（Debian、Ubuntu、RHEL 等）
remnanode-musl-{x64,arm64}.tar.gz           节点程序（Alpine）
remnanode-alpine-{x64,arm64}.tar.gz         同 musl，给 3.4.1-alpine.1 的旧脚本用
node-runtime-<版本>-glibc-{x64,arm64}.tar.{xz,gz}
node-runtime-<版本>-musl-x64.tar.{xz,gz}    Node.js 运行时（精简版）
install.sh                                  即 rwnode
```

每个文件都有 `.sha256`，安装时会校验。本地构建：`make package-glibc` / `make package-musl`（Linux 上需要 Node.js 24，其他系统借助 Docker）。

## 实现说明

- 代码改动只有两处：`src/modules/xray-core/native-xray-process.service.ts`，以及 `xray.module.ts` 里按 `XRAY_PROCESS_MANAGER=native` 切换实现。不设这个变量时行为与 Docker 版完全相同，方便继续合并上游更新。
- native 模式沿用 s6 的语义：启动后不自动重启（由面板健康检查负责拉起），停止时先 SIGTERM，3 秒后 SIGKILL；xray 输出写入 `/var/log/xray/current`，超过 10 MB 轮转。
- 配置通过 stdin 传给 Xray（`-config stdin:`），不落盘。Docker 版让 Xray 经 abstract unix socket 自己拉取配置（`-config @socket:/path`），这种写法 Xray 26.6.1 才支持，更早的版本会报 `open @rwint-...: no such file or directory`。
- node 被 SIGKILL 或 OOM 杀掉时，残留的 xray 会被清理（systemd 通过 cgroup，OpenRC 通过 pid 文件），不会占着端口。
- 内部 socket 和 token 每次启动随机生成（与 Docker 版的 `init-env.sh` 相同）。在 LXC 中，abstract socket 隔离在容器自己的网络命名空间里，比 Docker 的 `network_mode: host` 更安全。

## Xray 版本要求

默认 26.6.27，最低 **26.5.3**。更早的版本即使能读到配置也用不了：节点通过 unix socket 上的 `tunnel` 入站调用 Xray API（26.4.13 起支持，26.5.3 修复了连接时的崩溃），面板的流量统计用的 `GetUsersStats` 也是 26.4.13 才加入。

实测（Debian 13 / Alpine 3.24）：26.5.9、26.6.27、26.7.28 正常；26.3.27（GitHub 上标为 latest 的版本）、25.10.15、25.8.3 能启动但节点连不上 API；25.7.26 不认识 `tunnel` 协议。

`rwnode xray` 会拒绝低于 26.5.3 的版本；以前固定过的旧版本，`rwnode update` 时会自动换回默认版本。面板里给节点配置的自定义内核不经过 rwnode，同样需要 26.5.3 或更高。
