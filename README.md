# Jellyfin 一键安装/卸载脚本（Debian 13 LXC 直装）

在 Debian 13（trixie）LXC/VM 上一键安装/升级/完全卸载 Jellyfin：官方 APT 源直装（非 Docker、非 OCI）→ 自动写源 + 装包 + 验证；卸载自动清理软件包 / APT 源 / GPG 密钥 / 数据目录。

## 快速开始

在 Debian 13（root）上执行：

```bash
# 下载脚本
wget https://raw.githubusercontent.com/guochan2019/onekey-jellyfin/main/onekey-jellyfin.sh
# 运行（交互菜单）
bash onekey-jellyfin.sh
```

## 菜单选项

| 选项 | 说明 |
|------|------|
| **1. 安装 / 升级** | 环境预检（root/系统/依赖/端口/网络 5 项）→ 下载官方 install-debuntu.sh + SHA256 校验 → 执行官方脚本（自动装 GPG key、写 deb822 源、apt 安装 jellyfin metapackage）→ 验证（systemctl + `/health` 200） |
| **2. 完全卸载** | 停止/禁用服务 → `apt purge` jellyfin 全家（含 ffmpeg7）→ 删除 APT 源 + GPG 密钥 → 按选择删除/保留数据目录（默认保留）→ 清理残留 + 校验 |
| **0. 退出** | — |

## 环境要求

- **Debian 12/13**（官方仓库支持 bookworm/trixie）
- root 权限
- 网络可访问 `repo.jellyfin.org`（国内网络可能需要代理）

## 安装产物

| 项 | 路径 |
|----|------|
| 软件包 | jellyfin + jellyfin-server + jellyfin-web + jellyfin-ffmpeg7 |
| 系统服务 | `jellyfin.service`（systemd，用户 jellyfin） |
| 数据目录 | `/var/lib/jellyfin`（媒体库数据库） |
| 配置目录 | `/etc/jellyfin` |
| 日志目录 | `/var/log/jellyfin` |
| 缓存目录 | `/var/cache/jellyfin` |
| APT 源 | `/etc/apt/sources.list.d/jellyfin.sources` |
| GPG 密钥 | `/etc/apt/keyrings/jellyfin.gpg` |

## 注意事项

1. **卸载默认保留数据目录**（交互询问时默认 n）：若 `/var/lib/jellyfin` 是挂载点（PVE mp 挂载），删除将清空宿主侧数据且不可逆，脚本会先 `findmnt` 检测并警告。
2. **升级方式**：重跑脚本选 1（走官方脚本），或直接 `apt upgrade`。数据目录存在即保留，升级不丢媒体库。
3. **卸载不执行 `autoremove`**：避免连带删除系统工具导致意外问题。
4. **GPU 硬件转码**（可选）：需宿主侧直通 `/dev/dri`（card0 + renderD128，mode=0777），容器内 jellyfin 用户自动加入 video/render 组（官方 postinst 自动处理）。Jellyfin 后台 → 播放 → 转码 → 硬件加速选 VAAPI。
5. **首次初始化**：浏览器打开 `http://<IP>:8096`，设置管理员账号 + 添加媒体库。

## 验证

```bash
systemctl status jellyfin --no-pager                          # active (running)
curl -s -o /dev/null -w "%{http_code}" http://localhost:8096/health   # 200
id jellyfin                                                    # 应含 video/render 组
/usr/lib/jellyfin-ffmpeg/vainfo --display drm --device /dev/dri/renderD128  # VAAPI 可用（有 GPU 时）
```

## 卸载后重装

脚本选 2 时保留数据目录 → 再次选 1 安装，原媒体库/配置自动恢复。
