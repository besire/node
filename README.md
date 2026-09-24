## Remnawave Node

Node for Remnawave Panel.

Learn more about Remnawave Panel [here](https://docs.rw/).

## Alpine / LXC 精简版（无 Docker）

本仓库是 [remnawave/node](https://github.com/remnawave/node) 的 fork，额外提供不依赖 Docker 的部署方式：直接在 Alpine Linux 上运行，适合 LXC 容器（Proxmox、Incus）和小内存 VPS。功能与官方 Docker 镜像一致，面板侧无需任何改动。

- 系统要求：Alpine **3.23+**（需要 Node.js 24），x86_64 / aarch64，root 权限
- LXC：非特权容器即可，不需要开启 nesting
- 节点程序包约 3 MB，进程由 OpenRC 管理

一键安装（`SECRET_KEY` 从面板的节点页面复制，可以直接粘贴 `SECRET_KEY="..."` 整行）：

```sh
apk add curl
curl -fsSL https://github.com/besire/node/releases/latest/download/install.sh | sh -s -- --secret-key '面板里的 SECRET_KEY'
```

默认端口 2222，安装时用 `--port` 指定，之后可用 `sh install.sh update --port <端口>` 修改，面板里节点的端口需要保持一致。

常用命令：

| 操作 | 命令 |
|---|---|
| 状态 / 重启 | `rc-service remnanode status` / `restart` |
| 节点日志 | `tail -f /var/log/remnanode/node.log` |
| Xray 日志 | `xlogs` |
| 更新 | `sh install.sh update` |
| 卸载 | `sh install.sh uninstall`（加 `--purge` 同时删除配置和 Xray） |

完整说明（离线安装、Proxmox LXC 设置、构建与发布、实现细节）见 [deploy/alpine/README.md](deploy/alpine/README.md)。

官方 Docker 部署方式不受影响，仍按 [官方文档](https://docs.rw/) 使用。

# Contributors

Check [open issues](https://github.com/remnawave/panel/issues) to help the progress of this project.

<p align="center">
Thanks to the all contributors who have helped improve Remnawave:
</p>
<p align="center">
<a href="https://github.com/remnawave/node/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=remnawave/node" />
</a>
</p>
