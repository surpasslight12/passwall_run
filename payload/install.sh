#!/bin/sh
# install.sh — PassWall 一键安装脚本 (OpenWrt APK)
# PassWall installer for OpenWrt (APK package manager)
set -eu
set -o pipefail 2>/dev/null || true

log()      { printf '[INFO]  %s\n' "$*"; }
log_warn() { printf '[WARN]  %s\n' "$*"; }
err()      { printf '[ERROR] %s\n' "$*" >&2; }
die()      { err "$@"; exit 1; }

retry() {
  local max="$1" delay="$2"; shift 2
  local i=1
  while [ "$i" -le "$max" ]; do
    log "Attempt $i/$max: $*"
    "$@" && return 0
    [ "$i" -eq "$max" ] && { err "Failed after $max attempts: $*"; return 1; }
    log_warn "Attempt $i failed, retrying in ${delay}s…"
    sleep "$delay"; i=$((i + 1))
  done
}

# ── 检测安装包 / Detect packages ──
log "Starting PassWall installation…"

pw_pkg=""
for f in luci-app-passwall-*.apk luci-app-passwall_*.apk; do
  [ -e "$f" ] && { pw_pkg="$f"; break; }
done
[ -n "$pw_pkg" ] || die "luci-app-passwall package not found"

pw_ver=$(echo "$pw_pkg" | sed -E 's/luci-app-passwall[-_]//; s/[-_].*//')
log "PassWall: $pw_ver ($pw_pkg)"

zh_pkg=""
for f in luci-i18n-passwall-zh-cn-*.apk luci-i18n-passwall-zh-cn_*.apk; do
  [ -e "$f" ] && { zh_pkg="$f"; break; }
done

# ── 更新软件源 / Update package lists ──
retry 3 5 apk update || die "apk update failed"

# ── 构建安装列表 / Build install list ──
set -- "$pw_pkg"
[ -n "$zh_pkg" ] && set -- "$@" "$zh_pkg"

if [ -d depends ]; then
  for dep in depends/*.apk; do
    [ -e "$dep" ] && set -- "$@" "$dep"
  done
  log "Found $(find depends -maxdepth 1 -name '*.apk' 2>/dev/null | wc -l) dependency packages"
fi

# ── 卸载旧版本 / Remove old version ──
if apk list -I luci-app-passwall 2>/dev/null | grep -q "luci-app-passwall"; then
  INSTALLED_VER=$(apk list -I luci-app-passwall 2>/dev/null | sed -E 's/.*-([0-9][^ ]*).*/\1/' | head -1)
  log "Installed version: ${INSTALLED_VER:-unknown}, new version: $pw_ver"
  log "Removing existing PassWall before install"
  apk del luci-app-passwall luci-i18n-passwall-zh-cn 2>/dev/null || true
fi

# ── 安装 / Install ──
log "Installing $pw_ver…"
apk add --allow-untrusted "$@" || die "Installation failed"

log "PassWall $pw_ver installed successfully"
log "Restart: /etc/init.d/passwall restart"
