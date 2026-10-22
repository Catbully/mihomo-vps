#!/usr/bin/env bash
# shellcheck shell=bash
# 公共库：常量、日志、错误码、交互、JSON 与文件工具。由 mihomo.sh source，不单独执行。

# ---------- 路径常量 ----------
MH_HOME="${MH_HOME:-/etc/mihomo}"
MH_BIN="${MH_BIN:-/usr/local/bin/mihomo}"
MH_CONFIG="$MH_HOME/config.yaml"
MH_USERS="$MH_HOME/users.json"
MH_SETTINGS="$MH_HOME/settings.json"
MH_CERTS="$MH_HOME/certs"
MH_NFT_DIR="$MH_HOME/nft"
MH_NFT_FILE="$MH_NFT_DIR/forward.nft"
MH_NFT_DB="$MH_NFT_DIR/forwards.json"
MH_CLIENTS="$MH_HOME/clients"
MH_BACKUP_DIR="${MH_BACKUP_DIR:-/var/backups}"
MH_LOG_FILE="${MH_LOG_FILE:-/var/log/mihomo.log}"
MH_MAX_USERS="${MH_MAX_USERS:-32}"
MH_PORT_MIN="${MH_PORT_MIN:-20000}"
MH_PORT_MAX="${MH_PORT_MAX:-40000}"
MH_MIRROR="${MIHOMO_MIRROR:-}"
MH_GITHUB_API="https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"
MH_GITHUB_DL="https://github.com/MetaCubeX/mihomo/releases/download"
MH_REALITY_DEST_DEFAULT="itunes.apple.com:443"

# 供其它库文件使用，必须 export（否则 shellcheck 逐文件分析会报 SC2034）
export MH_HOME MH_BIN MH_CONFIG MH_USERS MH_SETTINGS MH_CERTS MH_NFT_DIR
export MH_NFT_FILE MH_NFT_DB MH_CLIENTS MH_BACKUP_DIR MH_LOG_FILE
export MH_MAX_USERS MH_PORT_MIN MH_PORT_MAX MH_MIRROR MH_GITHUB_API MH_GITHUB_DL
export MH_REALITY_DEST_DEFAULT

# ---------- 颜色 ----------
if [ -t 2 ]; then
  C_RED=$'\033[31m'
  C_GRN=$'\033[32m'
  C_YEL=$'\033[33m'
  C_BLU=$'\033[36m'
  C_OFF=$'\033[0m'
else
  C_RED=''
  C_GRN=''
  C_YEL=''
  C_BLU=''
  C_OFF=''
fi

# ---------- 日志 ----------
log() { printf '%s[*]%s %s\n' "$C_BLU" "$C_OFF" "$*" >&2; }
ok() { printf '%s[+]%s %s\n' "$C_GRN" "$C_OFF" "$*" >&2; }
warn() { printf '%s[!]%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }

# die <错误码> <说明...>：错误码为稳定英文常量，便于 grep 与排障。
die() {
  local code="$1"
  shift
  printf '%s[E]%s %s: %s\n' "$C_RED" "$C_OFF" "$code" "$*" >&2
  exit 1
}

# ---------- 环境检查 ----------
need_root() { [ "$(id -u)" -eq 0 ] || die E_NOT_ROOT "需要 root 权限运行"; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

need_cmd() {
  have_cmd "$1" || die E_MISSING_CMD "缺少命令：$1"
}

# ---------- 交互 ----------
# ask <提示> [默认值]：提示写 stderr，结果写 stdout，可安全用于命令替换。
ask() {
  local prompt="$1" def="${2:-}" ans=''
  if [ "$MH_ASSUME_YES" = 1 ] && [ -n "$def" ]; then
    printf '%s\n' "$def"
    return 0
  fi
  if [ -n "$def" ]; then
    printf '%s%s%s [%s]: ' "$C_BLU" "$prompt" "$C_OFF" "$def" >&2
  else
    printf '%s%s%s: ' "$C_BLU" "$prompt" "$C_OFF" >&2
  fi
  IFS= read -r ans || ans=''
  printf '%s\n' "${ans:-$def}"
}

# ask_yn <提示> [默认 y|n]：0=是，1=否。非交互时直接返回默认值。
ask_yn() {
  local prompt="$1" def="${2:-n}" ans=''
  if [ "$MH_ASSUME_YES" = 1 ]; then
    [ "$def" = "y" ]
    return $?
  fi
  printf '%s%s%s (y/n) [%s]: ' "$C_BLU" "$prompt" "$C_OFF" "$def" >&2
  IFS= read -r ans || ans=''
  case "${ans:-$def}" in
    y | Y | yes | YES) return 0 ;;
    *) return 1 ;;
  esac
}

confirm_danger() {
  warn "$1"
  ask_yn "确认继续？" "n" || die E_ABORTED "用户取消"
}

# ---------- 随机与端口 ----------
random_b64() {
  head -c "$1" /dev/urandom | base64 | tr -d '=\n'
}

random_hex() {
  head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'
}

# 密码会直接出现在分享链接的 userinfo 里（trojan://pw@host、tuic://uuid:pw@host）。
# RFC 3986 的 userinfo 不允许 '/', '+' 这类字符，务必用 base64url 字符集，
# 否则严格解析的客户端会把密码截断成一半，表现为"认证失败"。
random_password() { random_b64 18 | tr '+/' '-_'; }

random_uuid() {
  if [ -r /proc/sys/kernel/random/uuid ]; then
    tr -d '\n' < /proc/sys/kernel/random/uuid
    return 0
  fi
  random_hex 16 | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/'
}

# rand_port：在 MH_PORT_MIN..MH_PORT_MAX 内找一个 TCP 与 UDP 都空闲的端口
rand_port() {
  local p tries=0
  while [ "$tries" -lt 300 ]; do
    p=$(od -An -N2 -tu2 /dev/urandom | tr -d ' ')
    p=$((p % (MH_PORT_MAX - MH_PORT_MIN + 1) + MH_PORT_MIN))
    if ! port_in_use "$p" tcp && ! port_in_use "$p" udp; then
      printf '%s\n' "$p"
      return 0
    fi
    tries=$((tries + 1))
  done
  die E_NO_FREE_PORT "在 ${MH_PORT_MIN}-${MH_PORT_MAX} 内找不到空闲端口"
}

# ---------- 目录与备份 ----------
ensure_dirs() {
  mkdir -p "$MH_HOME" "$MH_CERTS" "$MH_NFT_DIR" "$MH_CLIENTS"
  chmod 700 "$MH_HOME" "$MH_CERTS"
}

# backup_now：把 /etc/mihomo 打包到 /var/backups，输出备份文件路径
backup_now() {
  local ts dest
  ts="$(date +%Y%m%d-%H%M%S)"
  dest="$MH_BACKUP_DIR/mihomo-$ts.tar.gz"
  mkdir -p "$MH_BACKUP_DIR"
  if [ -d "$MH_HOME" ]; then
    tar -czf "$dest" -C / "${MH_HOME#/}" 2>/dev/null || true
    printf '%s\n' "$dest"
  fi
}

# ---------- JSON 工具 ----------
json_require() {
  [ -f "$1" ] || die E_NO_STATE "状态文件不存在：$1（请先执行 install）"
}

# jget <jq过滤器> <文件>：取原始值（-r）
jget() {
  jq -r "$1" "$2"
}

# jset <文件> <jq过滤器...>：原地改写 JSON，原子替换并保持 600 权限
jset() {
  local file="$1"
  shift
  json_require "$file"
  local tmp="$file.tmp.$$"
  jq "$@" "$file" >"$tmp" || {
    rm -f "$tmp"
    die E_JSON "改写失败：$file"
  }
  chmod 600 "$tmp"
  mv -f "$tmp" "$file"
}
