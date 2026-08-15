# Jellyfin 一键安装/卸载脚本（Debian 13 LXC 直装）

在 Debian 13（trixie）LXC/VM 上一键安装/升级/卸载 Jellyfin：官方 APT 源直装（非 Docker、非 OCI）→ 自动写源 + 装包 + 权限修正 + 验证；卸载提供双模式（保留数据 / 彻底删除）。

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
| **1. 安装 / 升级** | **已安装时自动走升级**：`apt install --only-upgrade`（不重装官方脚本）→ 属主修正 → 验证。**未安装时走全新安装**：环境预检（root/系统/依赖/端口/网络 5 项）→ 数据库检测 → 下载官方 install-debuntu.sh + SHA256 校验 → 执行官方脚本（自动装 GPG key、写 deb822 源、apt 安装 jellyfin metapackage）→ 修正数据目录属主 → 验证（systemctl + `/health` 200 轮询） |
| **2. 完全卸载** | 双模式（见下）→ 停止/禁用服务 → remove 或 purge → 删除 APT 源 + GPG 密钥 → 清理残留 + 校验 |
| **0. 退出** | — |

### 卸载双模式

```
[1] 卸载但保留数据（apt remove，推荐）
    → 媒体库/配置/用户原目录保留，重装选 1 自动恢复
[2] 彻底卸载（apt purge）
    → 删除全部数据目录（挂载点会先警告），不可恢复
```

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

1. **卸载保留数据 = `apt remove`**：jellyfin 包 postrm 的 remove 分支不删任何数据目录（仅 purge 分支删），所以模式 1 数据原目录完整保留，重装即恢复——无需备份/迁移。
2. **彻底卸载（purge）会清空数据**：postrm purge 分支会 `rm -rf` 数据目录；挂载点目录本身删不掉（`Device or resource busy` 报错属预期，`|| true` 容错），但内容会被清空。挂载点残留由宿主侧手动清理（`pct set <CTID> -delete mpX` 后删宿主目录）。
3. **自动检测 mp 挂载点并显示映射目录**：安装前脚本检测 `/var/lib/jellyfin`、`/var/cache/jellyfin` 是否为 mp 挂载点，是则显示宿主映射路径（如 `pct set <CTID> -mpX /opt/jellyfin_deb,mp=/var/lib/jellyfin` 时显示 `→ /opt/jellyfin_deb`），安装完成再次显示"挂载来源"确认数据落在正确的宿主目录。若数据目录在容器本地 rootfs（未配置 mp 挂载），会警告"销毁/重建 LXC 将丢失媒体库数据"并给出挂载建议。**挂载本身由 PVE 宿主侧 `pct set -mpX` 配置决定，脚本只检测并显示。**
4. **安装前数据库检测**：检测到已有数据库时提示迁移风险（同版本重装/升级无损；跨版本如 preview→stable 可能不兼容）并确认，防止跨版本迁移破坏数据。
5. **安装后修正数据目录属主**：官方 postinst 只修 `/var/lib/jellyfin` 顶层，挂载点/预存在目录时子目录仍为 root 会导致 jellyfin 写库失败（health 503），脚本自动 `chown -R jellyfin:adm`。
6. **升级方式**：重跑脚本选 1（走官方脚本），或直接 `apt upgrade`。数据目录存在即保留，升级不丢媒体库。
7. **卸载不执行 `autoremove`**：避免连带删除系统工具导致意外问题。
8. **GPU 硬件转码**（可选）：需宿主侧直通 `/dev/dri`（card0 + renderD128，mode=0777），容器内 jellyfin 用户自动加入 video/render 组（官方 postinst 自动处理）。Jellyfin 后台 → 播放 → 转码 → 硬件加速选 VAAPI。
9. **首次初始化**：浏览器打开 `http://<IP>:8096`，设置管理员账号 + 添加媒体库。

## 验证

```bash
systemctl status jellyfin --no-pager                          # active (running)
curl -s -o /dev/null -w "%{http_code}" http://localhost:8096/health   # 200
id jellyfin                                                    # 应含 video/render 组
/usr/lib/jellyfin-ffmpeg/vainfo --display drm --device /dev/dri/renderD128  # VAAPI 可用（有 GPU 时）
```

## 数据保全场景

| 场景 | 数据去向 |
|------|----------|
| 卸载模式 1（remove） | 原目录保留，重装即恢复 |
| 卸载模式 2（purge） | 明确确认后清空 |
| 销毁 LXC 重建 | 数据在 mp 挂载点（宿主盘）时天然存活，重建后 mp 挂回即用 |
| 重装 | 检测已有数据库 → 同版本无损提示 → 复用 |
