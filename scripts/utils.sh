#!/usr/bin/env bash
# utils.sh — 工具函数库 / Utility functions
# Usage: source scripts/utils.sh

set -euo pipefail

trap 'rm -f /tmp/build-pkg-*.log 2>/dev/null' EXIT

# ── 日志 / Logging ──
log_info()  { printf '[INFO]  %s\n' "$*"; }
log_warn()  { printf '::warning::%s\n' "$*"; }
log_error() { printf '::error::%s\n' "$*"; }
die()       { log_error "$@"; exit 1; }

group_start() { echo "::group::$*"; }
group_end()   { echo "::endgroup::"; }

# ── 步骤计时 / Step timing ──
# Usage: step_start "Step name"  … work …  step_end
_STEP_NAME="" _STEP_T0=""
step_start() {
  _STEP_NAME="$1"
  _STEP_T0=$(date +%s)
  log_info "── $_STEP_NAME ──"
}
step_end() {
  if [ -z "$_STEP_T0" ]; then
    log_warn "step_end called without step_start"
    return
  fi
  local dur=$(( $(date +%s) - _STEP_T0 ))
  log_info "── $_STEP_NAME done (${dur}s) ──"
  _STEP_NAME="" _STEP_T0=""
}

# ── 重试 / Retry ──
# Usage: retry <max_attempts> <delay_sec> <command…>
retry() {
  local max="$1" delay="$2"; shift 2
  local i=1
  while [ "$i" -le "$max" ]; do
    log_info "Attempt $i/$max: $1"
    if "$@"; then return 0; fi
    [ "$i" -eq "$max" ] && { log_error "Failed after $max attempts: $1"; return 1; }
    log_warn "Attempt $i failed, retrying in ${delay}s…"
    sleep "$delay"
    i=$((i + 1))
  done
}

# ── Make 封装：并行 → 单线程降级 / Make wrapper with fallback ──
# Usage: make_pkg <target> [label]
make_pkg() {
  local target="$1" label="${2:-$1}"
  local jobs fallback_jobs
  jobs=$(nproc)
  fallback_jobs=$((jobs / 2))
  [ "$fallback_jobs" -lt 1 ] && fallback_jobs=1
  local logfile="/tmp/build-pkg-${label//\//_}-$$.log"

  # Build environment argument array with Rust/Cargo variables
  local env_args=()
  [ -n "${RUSTFLAGS:-}" ] && env_args+=("RUSTFLAGS=${RUSTFLAGS}")
  [ -n "${CARGO_INCREMENTAL:-}" ] && env_args+=("CARGO_INCREMENTAL=${CARGO_INCREMENTAL}")
  [ -n "${CARGO_NET_GIT_FETCH_WITH_CLI:-}" ] && env_args+=("CARGO_NET_GIT_FETCH_WITH_CLI=${CARGO_NET_GIT_FETCH_WITH_CLI}")
  [ -n "${CARGO_PROFILE_RELEASE_DEBUG:-}" ] && env_args+=("CARGO_PROFILE_RELEASE_DEBUG=${CARGO_PROFILE_RELEASE_DEBUG}")

  log_info "Compiling $label (-j$jobs)"
  if env ${env_args[@]+"${env_args[@]}"} make "$target" -j"$jobs" V=s >"$logfile" 2>&1; then
    rm -f "$logfile"; return 0
  fi

  if [ "$fallback_jobs" -lt "$jobs" ]; then
    log_warn "Parallel build failed for $label, retrying with -j${fallback_jobs}"
    if env ${env_args[@]+"${env_args[@]}"} make "$target" -j"$fallback_jobs" V=s >"$logfile" 2>&1; then
      rm -f "$logfile"; return 0
    fi
  fi

  log_warn "Retrying single-threaded for $label"
  if env ${env_args[@]+"${env_args[@]}"} make "$target" -j1 V=s >"$logfile" 2>&1; then
    rm -f "$logfile"; return 0
  fi

  log_error "Build failed: $label"
  tail -50 "$logfile" 2>/dev/null || true
  rm -f "$logfile"; return 1
}

# ── 磁盘空间检查 / Disk check ──
check_disk_space() {
  local min_gb="${1:-10}"
  local avail_gb=$(( $(df / --output=avail | tail -1 | tr -d ' ') / 1024 / 1024 ))
  if [ "$avail_gb" -lt "$min_gb" ]; then
    die "Disk space low: ${avail_gb}GB < ${min_gb}GB required"
  fi
  log_info "Disk: ${avail_gb}GB available"
}

# ── GitHub Actions 辅助 / GitHub Actions helpers ──
gh_set_env() {
  export "$1=$2"
  [ -n "${GITHUB_ENV:-}" ] && echo "$1=$2" >> "$GITHUB_ENV"
}

gh_summary() {
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] && printf '%s\n' "$1" >> "$GITHUB_STEP_SUMMARY"
}

# ── PassWall 源目录映射 / PassWall source directory mapping ──
# Maps a package name to its source directory inside the SDK tree.
# Must be called with cwd = SDK root.
map_passwall_source_dir() {
  local pkg="$1"
  case "$pkg" in
    shadowsocks-libev-*) echo "package/passwall-packages/shadowsocks-libev" ;;
    shadowsocks-rust-*) echo "package/passwall-packages/shadowsocks-rust" ;;
    shadowsocksr-libev-*) echo "package/passwall-packages/shadowsocksr-libev" ;;
    simple-obfs-*) echo "package/passwall-packages/simple-obfs" ;;
    v2ray-geoip|v2ray-geosite) echo "package/passwall-packages/v2ray-geodata" ;;
    luci-app-passwall|luci-i18n-passwall-zh-cn) echo "package/passwall-luci/luci-app-passwall" ;;
    *)
      [ -d "package/passwall-packages/$pkg" ] && echo "package/passwall-packages/$pkg" || return 1
      ;;
  esac
}

# ── APK 文件查找 / Find APK file by package name ──
# Finds the APK file for a given package name in a directory.
find_pkg_file() {
  local dir="$1" pkg="$2"
  find "$dir" -type f \( -name "${pkg}-[0-9]*.apk" -o -name "${pkg}_[0-9]*.apk" \) \
    | LC_ALL=C sort | head -n 1
}

# ── APK 版本规格 / Derive pinned "pkg=version" spec from APK filename ──
local_pkg_spec() {
  local dir="$1" pkg="$2" pkg_file version
  pkg_file=$(find_pkg_file "$dir" "$pkg" || true)
  [ -n "$pkg_file" ] || return 1
  version=$(basename "$pkg_file")
  version="${version%.apk}"
  version="${version#${pkg}-}"
  version="${version#${pkg}_}"
  [ -n "$version" ] || return 1
  printf '%s=%s\n' "$pkg" "$version"
}
