# Remnawave Node · Alpine / LXC（无 Docker）

在 Alpine Linux 上直接运行 Remnawave Node，不需要 Docker，适合 LXC 容器（Proxmox、Incus）和小内存 VPS。
功能与 Docker 版一致：面板看到的是同一个节点，所有接口、插件（nftables、torrent blocker、断连）、自定义内核、geodata 都保留。

| | Docker 镜像 | Alpine 版 |
|---|---|---|
| 系统 | node:24 Debian slim + s6-overlay | Alpine 3.23+，使用系统自带 `nodejs` |
| 进程管理 | s6 管理 node 和 xray | OpenRC `supervise-daemon` 管 node，node 直接管 xray |
| 节点程序包 | — | 约 3 MB（解压后 19 MB） |
| LXC 要求 | 需要 nesting / 特权容器才能跑 Docker | 非特权容器即可 |

## 要求

- Alpine **3.23 或更新**（依赖 Node.js 24，3.22 及更早版本只有 Node 22）
- x86_64 或 aarch64，root 权限

## 一键安装

```sh
apk add curl
curl -fsSL https://github.com/besire/node/releases/latest/download/install.sh | sh -s -- --secret-key '面板里的 SECRET_KEY'
```

- SECRET_KEY 可以直接粘贴面板给出的 `SECRET_KEY="..."` 整行，脚本会自动去掉前缀和引号。
- 默认端口 2222，用 `--port` 修改，需与面板中节点的端口一致。
- 不带 `--secret-key` 在终端运行时会提示输入。

安装脚本会：安装 `nodejs` 等系统包 → 下载节点包并校验 sha256 → 安装 Xray（校验官方 `.dgst`）、geocheck（校验 checksums）、ASN 数据库 → 写入 `/etc/remnanode/remnanode.env`（600 权限）→ 注册并启动 OpenRC 服务。

离线或自建包：

```sh
sh install.sh --tarball ./remnanode-alpine-x64.tar.gz --secret-key '...'
```

`sh install.sh --help` 查看全部选项（`--no-geocheck`、`--no-asn`、`--xray-version`、`--release` 等）。

## 日常使用

| 操作 | 命令 |
|---|---|
| 状态 / 重启 / 停止 | `rc-service remnanode status` / `restart` / `stop` |
| 节点日志 | `tail -f /var/log/remnanode/node.log` |
| Xray 日志 | `xlogs` |
| 导出当前 Xray 配置、按 IP 断连 | `remnanode-cli` |
| 更新（保留配置） | `sh install.sh update` |
| 修改端口 / 更换 SECRET_KEY | `sh install.sh update --port 3333`（或 `--secret-key '...'`），之后在面板里把节点端口改成一致 |
| 卸载（保留配置和 Xray） | `sh install.sh uninstall` |
| 彻底卸载 | `sh install.sh uninstall --purge` |

修改 `/etc/remnanode/remnanode.env` 后执行 `rc-service remnanode restart`。可选项（`SNI_VERIFICATION`、`NFTABLES_LOGGING` 等）与 Docker 版环境变量同名。

## Proxmox LXC 建议

- 模板选 Alpine 3.23+，**非特权容器即可，不需要开 nesting**。
- 文件句柄上限：非特权容器的上限由宿主决定，节点启动时会自动取可用的最大值。需要更高时在宿主的 `/etc/pve/lxc/<id>.conf` 加一行 `lxc.prlimit.nofile: 1048576`，然后重启容器。
- nftables 类插件（入站/出站过滤、torrent blocker）使用容器自己的网络命名空间，需要宿主内核支持 nf_tables（PVE 默认内核支持）。
- 断连功能依赖宿主内核的 `CONFIG_INET_DIAG_DESTROY`，可在宿主上执行 `grep INET_DIAG_DESTROY /boot/config-$(uname -r)` 确认。
- 容器在 NAT 后面时，要把 NODE_PORT 和 Xray 入站端口都转发进来。

## 构建与发布

在仓库里推一个 tag，`.github/workflows/build-alpine.yml` 会在 x64 和 arm64 runner 上各构建一次，并把以下文件附加到 GitHub Release：

```
remnanode-alpine-x64.tar.gz(.sha256)
remnanode-alpine-arm64.tar.gz(.sha256)
install.sh
```

本地构建：`sh scripts/package-alpine.sh`（或 `make package-alpine`）。在 Alpine 上直接构建，其他系统会借助 Docker 在 `node:24-alpine` 里构建，产物输出到 `build/`，架构跟随构建机器。

> fork 里的上游 Docker 工作流（`build-and-push.yml`）打 tag 时也会触发，没有 Docker Hub 凭据会失败，可以在 Actions 设置里禁用它。

## 实现说明

- 代码改动只有两处：新增 `src/modules/xray-core/native-xray-process.service.ts`，以及在 `xray.module.ts` 里按 `XRAY_PROCESS_MANAGER=native` 切换实现。不设这个变量时行为与 Docker 版完全相同，方便继续合并上游更新。
- native 模式沿用 s6 的语义：启动后不自动重启（由面板健康检查负责拉起），停止时先 SIGTERM，3 秒后 SIGKILL；xray 输出写入 `/var/log/xray/current`，超过 10 MB 轮转。
- node 被 SIGKILL 或 OOM 杀掉时，残留的 xray 会在 node 重新启动时通过 pid 文件识别并清理，避免端口被占用。
- 内部 socket 和 token 每次启动随机生成（与 Docker 版的 `init-env.sh` 相同）。在 LXC 中，abstract socket 隔离在容器自己的网络命名空间里，比 Docker `network_mode: host` 更安全。
