#!/bin/bash
# ============================================================
# onekey-jellyfin — Jellyfin 一键安装/升级/卸载脚本
# 适用环境: Debian 13 (trixie) LXC / VM
# 功能: 官方 APT 源直装 Jellyfin + 完全卸载（含 APT 源/密钥/数据清理）
# 说明: 安装走官方 install-debuntu.sh（trixie 官方支持）
# ============================================================
set -e

# ---------- 错误捕获 ----------
trap 'echo -e "\033[0;31m[ERROR] 脚本执行失败，请检查:\033[0m
  - 网络连接（能否访问 repo.jellyfin.org）
  - 是否以 root 运行
  - 系统是否 Debian 12+ (bookworm/trixie)
  - 尝试: bash -x onekey-jellyfin.sh" >&2' ERR

# ---------- 彩色输出 ----------
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ---------- 配置 ----------
REPO_BASE="https://repo.jellyfin.org"
INSTALL_SCRIPT="${REPO_BASE}/install-debuntu.sh"
CHECKSUM_URL="${REPO_BASE}/install-debuntu.sh.sha256sum"
DATA_DIRS="/var/lib/jellyfin /etc/jellyfin /var/log/jellyfin /var/cache/jellyfin"

# ---------- 检测 root ----------
if [ "$(id -u)" -ne 0 ]; then
  err "请以 root 用户运行 (当前非 root)"
fi

# ---------- 版本检测 ----------
get_current_ver() {
  if ! dpkg -l jellyfin >/dev/null 2>&1; then
    echo ""; return
  fi
  dpkg -l jellyfin 2>/dev/null | awk '/^ii[ ]+jellyfin[ ]+/ {print $3}' | head -1
}

# ---------- 预检 ----------
precheck() {
  info "=== 环境预检 ==="
  local PASS=0 FAIL=0

  # 1. root
  if [ "$(id -u)" -eq 0 ]; then PASS=$((PASS+1)); info "  [1/5] root 权限          ✅"; else FAIL=$((FAIL+1)); err "  [1/5] root 权限          ❌"; fi

  # 2. 操作系统
  . /etc/os-release 2>/dev/null || true
  if [ "$ID" = "debian" ] && { [ "$VERSION_CODENAME" = "bookworm" ] || [ "$VERSION_CODENAME" = "trixie" ]; }; then
    PASS=$((PASS+1)); info "  [2/5] 系统 ${NAME} ${VERSION}  ✅"
  else
    FAIL=$((FAIL+1)); warn "  [2/5] 系统 ${NAME} ${VERSION}  ❌ (官方支持 bookworm/trixie)"
  fi

  # 3. 依赖工具
  MISSING=""
  for t in curl sha256sum; do
    command -v "$t" >/dev/null 2>&1 || MISSING="$MISSING $t"
  done
  if [ -z "$MISSING" ]; then
    PASS=$((PASS+1)); info "  [3/5] 依赖工具 (curl/sha256sum)  ✅"
  else
    FAIL=$((FAIL+1)); err "  [3/5] 缺少依赖:${MISSING}，请先 apt install curl"
  fi

  # 4. 端口占用 (8096)
  PORT_PID=$(ss -tlnp 2>/dev/null | grep -E "[:.]8096\b" | grep -oP 'users:\(\("\K[^"]+' | head -1 || true)
  if [ -z "$PORT_PID" ] || [ "$PORT_PID" = "jellyfin" ]; then
    PASS=$((PASS+1)); info "  [4/5] 端口 8096          ✅ (${PORT_PID:-空闲})"
  else
    FAIL=$((FAIL+1)); err "  [4/5] 端口 8096 被 ${PORT_PID} 占用 ❌"
  fi

  # 5. 网络连通 (repo.jellyfin.org)
  CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 8 --max-time 15 "$INSTALL_SCRIPT" || echo "000")
  if [ "$CODE" = "200" ] || [ "$CODE" = "301" ] || [ "$CODE" = "302" ]; then
    PASS=$((PASS+1)); info "  [5/5] repo.jellyfin.org  ✅ (HTTP $CODE)"
  else
    FAIL=$((FAIL+1)); err "  [5/5] repo.jellyfin.org  ❌ (HTTP $CODE)，国内网络可能需要代理"
  fi

  echo "----------------------------------------"
  if [ "$FAIL" -eq 0 ]; then
    info "  结论: 环境检查通过 (${PASS}/${PASS} 项)，继续安装"
  else
    err "  结论: 环境检查未通过 (${FAIL} 项失败)"
  fi
}

# ---------- 挂载状态展示 ----------
show_mounts() {
  echo ""
  info "=== 数据目录挂载状态 ==="
  for d in /var/lib/jellyfin /var/cache/jellyfin; do
    MOUNT_SRC=$(findmnt -n -o SOURCE "$d" 2>/dev/null || echo "")
    if [ -n "$MOUNT_SRC" ]; then
      info "  $d → $MOUNT_SRC (mp 挂载，宿主侧数据)"
    else
      warn "  $d → (容器本地 rootfs)"
    fi
  done
  echo ""
}

# ---------- 升级（已安装时） ----------
do_upgrade() {
  echo ""
  warn "========== 升级 Jellyfin =========="
  echo ""
  local VER
  VER=$(get_current_ver)
  info "检测到 Jellyfin ${VER} 已安装，执行升级（apt install --only-upgrade）"

  # 1. 更新 APT 源
  info "=== 1/3 更新 APT 源 ==="
  apt-get update -qq

  # 2. 升级 jellyfin 全家（仅升级，不重装官方脚本）
  info "=== 2/3 升级 jellyfin 软件包 ==="
  apt-get install --only-upgrade -y jellyfin jellyfin-server jellyfin-web jellyfin-ffmpeg7

  # 3. 修正属主 + 验证
  info "=== 3/3 修正数据目录属主并验证 ==="
  if [ -d /var/lib/jellyfin ]; then
    chown -R jellyfin:adm /var/lib/jellyfin
    info "  ✓ /var/lib/jellyfin 递归属主已修正为 jellyfin:adm"
  fi
  HEALTH_CODE="000"
  for i in $(seq 1 12); do
    if systemctl is-active jellyfin >/dev/null 2>&1; then
      HEALTH_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://localhost:8096/health 2>/dev/null || echo "000")
      [ "$HEALTH_CODE" = "200" ] && break
    fi
    sleep 5
  done
  if systemctl is-active jellyfin >/dev/null 2>&1; then
    info "  ✓ jellyfin 服务运行中"
  else
    err "  jellyfin 服务未运行，请检查: journalctl -u jellyfin -n 50"
  fi
  if [ "$HEALTH_CODE" = "200" ]; then
    info "  ✓ 健康检查 http://localhost:8096/health = 200"
  else
    warn "  ⚠ 健康检查返回 $HEALTH_CODE（服务可能仍在初始化，稍后重试）"
  fi

  VER=$(get_current_ver)
  echo ""
  info "========== 升级完成 =========="
  info "  Jellyfin 版本 : ${VER:-未知}"
  LIB_MOUNT=$(findmnt -n -o SOURCE /var/lib/jellyfin 2>/dev/null || echo "容器本地 rootfs")
  info "  数据目录      : /var/lib/jellyfin (媒体库数据库)"
  info "  挂载来源      : ${LIB_MOUNT}"
  if [ "$LIB_MOUNT" = "容器本地 rootfs" ]; then
    warn "  ⚠ 数据目录在容器本地 rootfs —— 销毁/重建 LXC 将丢失媒体库数据!"
  fi
  info "  升级方式      : 重跑本脚本选 1，或 apt upgrade"
  exit 0
}

# ---------- 安装/升级 ----------
do_install() {
  echo ""
  warn "========== 安装 / 升级 Jellyfin =========="
  echo ""
  precheck
  show_mounts

  # 已安装 → 走升级分支（不重装，直接 apt upgrade）
  if [ -n "$(get_current_ver)" ]; then
    do_upgrade
    return
  fi

  # 1. 安装依赖
  info "=== 1/5 安装依赖 (curl) ==="
  apt-get update -qq
  apt-get install -y -qq curl

  # 1.5 检测已有数据库（防跨版本迁移破坏数据——2026-08-15 OCI preview 数据库被 stable 迁移污染事故）
  DB_FILE="/var/lib/jellyfin/data/jellyfin.db"
  if [ -f "$DB_FILE" ]; then
    echo ""
    warn "========== 检测到已有 Jellyfin 数据库 =========="
    warn "  路径: ${DB_FILE}"
    warn "  继续安装将对其执行数据库迁移:"
    warn "    - 相同版本重装/升级: 无损（保留媒体库/配置/用户）"
    warn "    - 跨版本 (preview→stable 等): 可能不兼容，建议先备份"
    warn "  备份命令: cp -a ${DB_FILE} ${DB_FILE}.bak"
    echo ""
    read -p "是否继续？(y/n，默认 y): " DB_CONFIRM </dev/tty
    DB_CONFIRM=${DB_CONFIRM:-y}
    if [ "$DB_CONFIRM" != "y" ] && [ "$DB_CONFIRM" != "Y" ]; then
      info "已取消安装（数据库未改动）"
      exit 0
    fi
    echo ""
  fi

  # 2. 下载官方脚本 + 校验
  info "=== 2/5 下载官方安装脚本 + SHA256 校验 ==="
  cd /root
  rm -f install-debuntu.sh install-debuntu.sh.sha256sum
  curl -s "$INSTALL_SCRIPT" -O
  curl -s "$CHECKSUM_URL" -O
  sha256sum -c install-debuntu.sh.sha256sum
  # sha256sum -c 输出 "install-debuntu.sh: OK"；校验失败会非零退出（set -e 触发 trap）

  # 3. 执行官方脚本（自动: 装 GPG key → 写 deb822 源 → apt update → 装 jellyfin metapackage）
  info "=== 3/5 执行官方安装脚本 ==="
  bash install-debuntu.sh

  # 4. 修正数据目录属主（官方 postinst 只修 /var/lib/jellyfin 顶层；
  #    挂载点/预存在目录时子目录(config/data 等)仍为 root，
  #    jellyfin 用户写不进去 → 启动报 Permission denied → health 503）
  info "=== 4/5 修正数据目录属主 ==="
  if [ -d /var/lib/jellyfin ]; then
    chown -R jellyfin:adm /var/lib/jellyfin
    info "  ✓ /var/lib/jellyfin 递归属主已修正为 jellyfin:adm"
  fi

  # 5. 验证（轮询最多 60s，避免迁移期误报 503）
  info "=== 5/5 验证 ==="
  HEALTH_CODE="000"
  for i in $(seq 1 12); do
    if systemctl is-active jellyfin >/dev/null 2>&1; then
      HEALTH_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://localhost:8096/health 2>/dev/null || echo "000")
      [ "$HEALTH_CODE" = "200" ] && break
    fi
    sleep 5
  done
  if systemctl is-active jellyfin >/dev/null 2>&1; then
    info "  ✓ jellyfin 服务运行中"
  else
    err "  jellyfin 服务未运行，请检查: journalctl -u jellyfin -n 50"
  fi
  if [ "$HEALTH_CODE" = "200" ]; then
    info "  ✓ 健康检查 http://localhost:8096/health = 200"
  else
    warn "  ⚠ 健康检查返回 $HEALTH_CODE（服务可能仍在初始化，稍后重试）"
  fi

  VER=$(get_current_ver)
  echo ""
  info "========== 安装完成 =========="
  info "  Jellyfin 版本 : ${VER:-未知}"
  info "  Web 地址      : http://<本机IP>:8096"
  LIB_MOUNT=$(findmnt -n -o SOURCE /var/lib/jellyfin 2>/dev/null || echo "容器本地 rootfs")
  info "  数据目录      : /var/lib/jellyfin (媒体库数据库)"
  info "  挂载来源      : ${LIB_MOUNT}"
  if [ "$LIB_MOUNT" = "容器本地 rootfs" ]; then
    warn "  ⚠ 数据目录在容器本地 rootfs —— 销毁/重建 LXC 将丢失媒体库数据!"
    warn "    建议在 PVE 宿主配置 mp 挂载到宿主盘, 如: pct set <CTID> -mpX /opt/jellyfin_deb,mp=/var/lib/jellyfin"
  fi
  info "  配置目录      : /etc/jellyfin"
  info "  升级方式      : 重跑本脚本选 1，或 apt upgrade"
  warn "  提示: 若数据目录为挂载点(mp)，重装/升级不丢数据；GPU 直通需宿主侧 dev0/dev1 配置"
  exit 0
}

# ---------- 卸载 ----------
uninstall_jellyfin() {
  echo ""
  warn "========== 完全卸载 Jellyfin =========="
  echo ""
  read -p "确认卸载 Jellyfin？(y/n，默认 y): " CONFIRM </dev/tty
  CONFIRM=${CONFIRM:-y}
  if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
    info "已取消卸载"
    exit 0
  fi

  # 卸载方式：默认 apt remove（数据目录原样保留，postrm remove 分支不删数据）
  # 仅当用户明确要彻底删除数据时，才用 purge（postrm purge 分支 rm -rf 数据目录）
  echo ""
  echo "请选择卸载方式："
  echo "  [1] 卸载但保留数据（apt remove，推荐——媒体库/配置原目录保留，重装即恢复）"
  echo "  [2] 彻底卸载（apt purge——删除全部数据目录，不可恢复）"
  echo ""
  read -p "请输入 (1/2，默认 1): " UNINST_MODE </dev/tty
  UNINST_MODE=${UNINST_MODE:-1}
  if [ "$UNINST_MODE" != "1" ] && [ "$UNINST_MODE" != "2" ]; then
    err "无效的卸载方式: ${UNINST_MODE}（请输入 1 或 2）"
  fi

  if [ "$UNINST_MODE" = "2" ]; then
    echo ""
    warn "⚠ 彻底卸载将删除数据目录:"
    for d in /var/lib/jellyfin /var/cache/jellyfin; do
      if findmnt "$d" >/dev/null 2>&1; then
        warn "  $d 是挂载点(mount point) —— 删除将清空宿主侧数据!"
      fi
    done
    read -p "确认彻底删除全部数据目录 (${DATA_DIRS})？(y/n，默认 n): " DEL_DATA </dev/tty
    DEL_DATA=${DEL_DATA:-n}
    if [ "$DEL_DATA" != "y" ] && [ "$DEL_DATA" != "Y" ]; then
      info "已改为保留数据模式（apt remove）"
      UNINST_MODE=1
    fi
  fi

  # 1. 停止并禁用服务
  info "=== 1/4 停止并禁用 jellyfin 服务 ==="
  systemctl stop jellyfin 2>/dev/null || true
  systemctl disable jellyfin 2>/dev/null || true

  # 2. 卸载包
  if [ "$UNINST_MODE" = "2" ]; then
    # 彻底卸载：purge（postrm 会删除数据目录，符合用户明确意图）
    info "=== 2/4 彻底卸载 jellyfin 软件包 (purge) ==="
    apt-get purge -y jellyfin jellyfin-server jellyfin-web jellyfin-ffmpeg7
  else
    # 保留数据：apt remove（postrm remove 分支不删任何数据目录）
    info "=== 2/4 卸载 jellyfin 软件包 (remove，保留数据) ==="
    apt-get remove -y jellyfin jellyfin-server jellyfin-web jellyfin-ffmpeg7
  fi

  # 3. 删除 APT 源 + 密钥（install-debuntu.sh 写入的产物）
  info "=== 3/4 删除 APT 源和 GPG 密钥 ==="
  rm -f /etc/apt/sources.list.d/jellyfin.sources
  rm -f /etc/apt/sources.list.d/jellyfin.list
  rm -f /etc/apt/keyrings/jellyfin.gpg
  apt-get update -qq

  # 4. 清理遗留安装脚本
  info "=== 4/4 清理残留 ==="
  rm -f /root/install-debuntu.sh /root/install-debuntu.sh.sha256sum

  echo ""
  info "========== 卸载完成 =========="
  if dpkg -l jellyfin 2>/dev/null | grep -qE '^ii\s+jellyfin\s'; then
    warn "  ⚠ jellyfin 包仍存在: $(dpkg -l jellyfin | awk '/^ii[ ]+jellyfin[ ]+/ {print $3}' | head -1)"
  else
    info "  ✓ jellyfin 软件包已移除（rc 残留配置不影响）"
  fi
  if command -v jellyfin >/dev/null 2>&1; then
    warn "  ⚠ jellyfin 命令仍然存在，请检查"
  else
    info "  ✓ jellyfin 命令已移除"
  fi
  info "  ✓ APT 源/密钥已清理"
  if [ "$UNINST_MODE" = "2" ]; then
    info "  ✓ 数据目录已彻底删除（重装将全新初始化）"
  else
    info "  ✓ 数据目录原样保留: /var/lib/jellyfin 等（重装选 1 自动恢复原媒体库）"
  fi
  exit 0
}

# ---------- 菜单 ----------
echo ""
echo "========================================"
echo "  Jellyfin 一键安装/升级/卸载脚本"
echo "========================================"
echo ""

CURRENT_VER=$(get_current_ver)
if [ -n "$CURRENT_VER" ]; then
  info "检测到 Jellyfin ${CURRENT_VER} 已安装"
else
  info "Jellyfin 未安装"
fi

echo ""
echo "请选择操作："
echo "  1. 安装 / 升级 Jellyfin（官方 APT 源）"
echo "  2. 完全卸载 Jellyfin"
echo "  0. 退出"
echo ""
read -p "请输入选项 (0-2，默认 1): " ACTION </dev/tty
echo ""

case "$ACTION" in
  2) uninstall_jellyfin ;;
  0) info "已退出"; exit 0 ;;
  1|"")
    do_install
    ;;
  *) err "无效选项: ${ACTION}" ;;
esac
