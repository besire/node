# remnanode-thin

不用 Docker 的精简版 Remnawave Node：一条命令安装，内存和磁盘占用更小。

## Remnawave Node

Node for Remnawave Panel.

Learn more about Remnawave Panel [here](https://docs.rw/).

## Linux 一键部署（无 Docker）

remnanode-thin 是 [remnawave/node](https://github.com/remnawave/node) 的 fork，额外提供不依赖 Docker 的部署方式：Debian、Ubuntu、Rocky / Alma、Alpine 等主流发行版，LXC 容器（Proxmox、Incus）、VPS、虚拟机都可以。功能与官方 Docker 镜像一致，面板侧无需任何改动。

```sh
wget -qO- https://github.com/besire/remnanode-thin/releases/latest/download/install.sh | sh
```

没有 wget 的系统用 `curl -fsSL <同一个地址> | sh`。脚本会打开管理面板：选 `1` 安装，输入节点端口，粘贴面板中的 SECRET_KEY 即可。以后输入 **`rwnode`** 随时打开面板（启停、更新、改端口、换 SECRET_KEY、切换 Xray 版本、看日志、卸载）。

- 系统要求：glibc ≥ 2.28 的发行版（Debian 10+、Ubuntu 20.04+、RHEL 8+）或 Alpine（3.23+，3.22 仅 x86_64），x86_64 / aarch64，root 权限
- LXC：非特权容器即可，不需要开启 nesting
- 不依赖包管理器：Debian / Ubuntu 上不执行 `apt-get update`，Node.js 24 使用独立的精简运行时，不影响系统里的其他软件

无人值守安装、支持矩阵、资源占用、Proxmox LXC 设置、构建与发布见 [deploy/linux/README.md](deploy/linux/README.md)。

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
