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
# 备份目录：⚠ 默认在容器 rootfs，销毁 LXC 重建会丢失！
# 若需销毁重建后仍可恢复，请改为宿主持久路径（mp 挂载进来的目录），
# 例如: BK_DIR="/var/lib/jellyfin-backup"（需在 PVE 配置 mp: /opt/jellyfin/backup,mp=/var/lib/jellyfin-backup）
# 或复用已有 mp 挂载点下的目录，如 BK_DIR="/mnt/nvme1/jellyfin-backup"
BK_DIR="/root/jellyfin-backup"

# ---------- 检测 root ----------
if [ "$(id -u)" -ne 0 ]; then
  err "请以 root 用户运行 (当前非 root)"
fi

# ---------- 版本检测 ----------
get_current_ver() {
  if ! dpkg -l jellyfin >/dev/null 2>&1; then
    echo ""; return
  fi
  dpkg -l jellyfin 2>/dev/null | awk '/^ii  jellyfin / {print $3}' || echo ""
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

# ---------- 安装/升级 ----------
do_install() {
  echo ""
  warn "========== 安装 / 升级 Jellyfin =========="
  echo ""
  precheck

  # 1. 安装依赖
  info "=== 1/6 安装依赖 (curl) ==="
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
  info "=== 2/6 下载官方安装脚本 + SHA256 校验 ==="
  cd /root
  rm -f install-debuntu.sh install-debuntu.sh.sha256sum
  curl -s "$INSTALL_SCRIPT" -O
  curl -s "$CHECKSUM_URL" -O
  sha256sum -c install-debuntu.sh.sha256sum
  # sha256sum -c 输出 "install-debuntu.sh: OK"；校验失败会非零退出（set -e 触发 trap）

  # 3. 执行官方脚本（自动: 装 GPG key → 写 deb822 源 → apt update → 装 jellyfin metapackage）
  info "=== 3/6 执行官方安装脚本 ==="
  bash install-debuntu.sh

  # 3.5 检测卸载备份并询问恢复（卸载时保留的数据在 ${BK_DIR}）
  if [ -d "$BK_DIR" ] && [ -n "$(ls -A "$BK_DIR" 2>/dev/null)" ]; then
    echo ""
    warn "========== 检测到数据备份 =========="
    warn "  位置: ${BK_DIR}"
    warn "  内容: $(ls "$BK_DIR" | tr '\n' ' ')"
    warn "  恢复将把备份复制回数据目录（覆盖本次全新初始化的数据）"
    echo ""
    read -p "是否恢复备份数据？(y/n，默认 y): " RESTORE_DATA </dev/tty
    RESTORE_DATA=${RESTORE_DATA:-y}
    if [ "$RESTORE_DATA" = "y" ] || [ "$RESTORE_DATA" = "Y" ]; then
      info "=== 4/6 恢复备份数据 ==="
      systemctl stop jellyfin 2>/dev/null || true
      # 备份目录名: <父目录>-jellyfin → 还原为 /<父目录>/jellyfin
      for bk in "$BK_DIR"/*; do
        [ -d "$bk" ] || continue
        BK_NAME=$(basename "$bk")
        PARENT_DIR="${BK_NAME%-*}"
        RESTORE_PATH="/${PARENT_DIR}/jellyfin"
        if [ "$PARENT_DIR" = "var-lib" ]; then RESTORE_PATH="/var/lib/jellyfin"; fi
        if [ "$PARENT_DIR" = "etc" ]; then RESTORE_PATH="/etc/jellyfin"; fi
        if [ "$PARENT_DIR" = "var-log" ]; then RESTORE_PATH="/var/log/jellyfin"; fi
        if [ "$PARENT_DIR" = "var-cache" ]; then RESTORE_PATH="/var/cache/jellyfin"; fi
        mkdir -p "$RESTORE_PATH"
        cp -a "$bk/." "$RESTORE_PATH/"
        info "  ✓ 已恢复 $RESTORE_PATH"
      done
      info "  备份数据已恢复（属主修正见下一步）"
    else
      info "=== 4/6 跳过备份恢复（使用全新初始化数据） ==="
    fi
    echo ""
  fi

  # 4. 修正数据目录属主（官方 postinst 只修 /var/lib/jellyfin 顶层；
  #    挂载点/预存在目录时子目录(config/data 等)仍为 root，
  #    jellyfin 用户写不进去 → 启动报 Permission denied → health 503）
  info "=== 5/6 修正数据目录属主 ==="
  if [ -d /var/lib/jellyfin ]; then
    chown -R jellyfin:adm /var/lib/jellyfin
    info "  ✓ /var/lib/jellyfin 递归属主已修正为 jellyfin:adm"
  fi

  # 5. 验证（轮询最多 60s，避免迁移期误报 503）
  info "=== 6/6 验证 ==="
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
  info "  数据目录      : /var/lib/jellyfin (媒体库数据库)"
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

  # 0. 数据目录挂载点检测（mp 挂载时数据在宿主侧，删除不可逆）
  echo ""
  warn "⚠ 数据目录删除提示:"
  for d in /var/lib/jellyfin /var/cache/jellyfin; do
    if findmnt "$d" >/dev/null 2>&1; then
      warn "  $d 是挂载点(mount point) —— 删除将清空宿主侧数据!"
    fi
  done
  read -p "是否保留数据目录 (${DATA_DIRS})？(y/n，默认 y 保留): " KEEP_DATA </dev/tty
  KEEP_DATA=${KEEP_DATA:-y}

  # 1. 停止并禁用服务（必须先停服，再搬数据，避免搬移运行中的数据库）
  info "=== 1/5 停止并禁用 jellyfin 服务 ==="
  systemctl stop jellyfin 2>/dev/null || true
  systemctl disable jellyfin 2>/dev/null || true

  # 2. 若保留数据：purge 前先把数据目录复制到备份（jellyfin-server postrm 会 rm -rf 全部数据目录，
  #    挂载点目录本身删不掉但内容会被清空 → 必须主动备份才能真保留。
  #    用 cp -a 而非 mv：/var/lib/jellyfin 可能是 mp 挂载点，mv 整个挂载点会导致 mount 失效/宿主侧异常。
  #    备份目录 ${BK_DIR}（顶部变量可配），重装时自动检测恢复）
  if [ "$KEEP_DATA" = "y" ] || [ "$KEEP_DATA" = "Y" ]; then
    # 备份位置安全提示：BK_DIR 不在挂载点 = 在 rootfs，销毁 LXC 重建会丢
    BK_MOUNTED=0
    findmnt "$BK_DIR" >/dev/null 2>&1 && BK_MOUNTED=1
    if [ "$BK_MOUNTED" = "0" ]; then
      warn "  ⚠ 备份目录 ${BK_DIR} 在容器 rootfs 内"
      warn "    销毁 LXC 重建后备份会丢失！建议改脚本顶部 BK_DIR 为 mp 挂载的宿主持久路径"
      warn "    （例: 配置 mp: /opt/jellyfin/backup,mp=/var/lib/jellyfin-backup，再设 BK_DIR=/var/lib/jellyfin-backup）"
      echo ""
      read -p "仍要备份到该位置？(y/n，默认 y): " BK_CONFIRM </dev/tty
      BK_CONFIRM=${BK_CONFIRM:-y}
      if [ "$BK_CONFIRM" != "y" ] && [ "$BK_CONFIRM" != "Y" ]; then
        info "已取消备份（数据目录将由 postrm 清空，慎重）"
        exit 0
      fi
    fi
    info "=== 2/5 备份数据目录 → ${BK_DIR} ==="
    rm -rf "$BK_DIR"
    mkdir -p "$BK_DIR"
    for d in /var/lib/jellyfin /etc/jellyfin /var/log/jellyfin /var/cache/jellyfin; do
      if [ -d "$d" ] && [ -n "$(ls -A "$d" 2>/dev/null)" ]; then
        # 目录名带父目录前缀，避免 4 个 basename 都是 "jellyfin" 互相覆盖
        BK_NAME="$(basename "$(dirname "$d")")-$(basename "$d")"
        cp -a "$d" "${BK_DIR}/${BK_NAME}"
        info "  ✓ 已备份 $d → ${BK_NAME}"
      else
        info "  - 跳过（不存在或为空）: $d"
      fi
    done
  fi

  # 3. 卸载包（purge 连 conffile 一起删；不执行 autoremove——避免连带删系统工具。
  #    注意: jellyfin-server postrm 会 rm -rf 数据目录，但第 2 步已把数据搬走，
  #    这里 purge 只会删掉空目录/无影响）
  info "=== 3/5 卸载 jellyfin 软件包 ==="
  apt-get purge -y jellyfin jellyfin-server jellyfin-web jellyfin-ffmpeg7

  # 4. 删除 APT 源 + 密钥（install-debuntu.sh 写入的产物）
  info "=== 4/5 删除 APT 源和 GPG 密钥 ==="
  rm -f /etc/apt/sources.list.d/jellyfin.sources
  rm -f /etc/apt/sources.list.d/jellyfin.list
  rm -f /etc/apt/keyrings/jellyfin.gpg
  apt-get update -qq

  # 5. 清理遗留安装脚本
  info "=== 5/5 清理残留 ==="
  rm -f /root/install-debuntu.sh /root/install-debuntu.sh.sha256sum

  echo ""
  info "========== 卸载完成 =========="
  if dpkg -l jellyfin >/dev/null 2>&1; then
    warn "  ⚠ jellyfin 包仍存在: $(dpkg -l jellyfin | awk '/^ii/ {print $3}')"
  else
    info "  ✓ jellyfin 软件包已移除"
  fi
  if command -v jellyfin >/dev/null 2>&1; then
    warn "  ⚠ jellyfin 命令仍然存在，请检查"
  else
    info "  ✓ jellyfin 命令已移除"
  fi
  info "  ✓ APT 源/密钥已清理"
  if [ "$KEEP_DATA" = "y" ] || [ "$KEEP_DATA" = "Y" ]; then
    info "  ✓ 数据已备份至 ${BK_DIR}"
    info "    下次安装将自动检测并询问恢复（选 1 安装时）"
    info "    提示: 若 /var/lib/jellyfin 是 mp 挂载点(宿主盘)，销毁重建 LXC 后数据仍在宿主侧，"
    info "    重建后 mp 挂载回来即可用，无需依赖本备份"
  else
    info "  ✓ 数据目录已删除（如需重装将全新初始化）"
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
