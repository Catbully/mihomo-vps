#!/usr/bin/env bash
# mihomo.sh —— Debian/Ubuntu/Alpine 上的 mihomo 服务端安装与运维入口
#
# 用法：
#   ./mihomo.sh                    交互菜单
#   ./mihomo.sh install [--yes]    安装（或重装）mihomo 入站代理
#   ./mihomo.sh reconfig           修改协议/端口/证书
#   ./mihomo.sh user <add|remove|list|show|export|disable> [参数]
#   ./mihomo.sh forward <add|del|list|flush|apply> [参数]
#   ./mihomo.sh clients [--all|--user NAME] [--full] [--qr]
#   ./mihomo.sh update             更新 mihomo 内核（保留配置）
#   ./mihomo.sh status             状态与诊断
#   ./mihomo.sh uninstall [--purge]
#   ./mihomo.sh self-install       把脚本落地到本机并安装 mihomo-vps 命令（install 会自动做）
# 一键装（单文件自举：缺 lib/ 时自动下载仓库压缩包再执行，stdin 仍归终端）：
#   curl -fsSLo /tmp/mihomo.sh https://raw.githubusercontent.com/Catbully/mihomo-vps/main/mihomo.sh
#   sudo bash /tmp/mihomo.sh
#   （已是 root 可直接 bash <(curl -fsSL <上面这个 URL>)；
#     切勿写 sudo bash <(curl ...)：sudo 会关掉多余 fd，直接报 /dev/fd/63 不存在）
#   sudo bash <(curl -fsSL https://raw.githubusercontent.com/Catbully/mihomo-vps/main/mihomo.sh)
#
# 设计约束（均来自实测，勿随意改动）：
#   1. 只做"入站代理 + nftables 端口转发"，不做 TUN 网关、不做出站链式中转。
#   2. mihomo -t 是浅校验：不校验证书、REALITY 私钥、SS 密钥长度、reality 与证书互斥。
#      因此每次变更都必须走"真启动 + 端口校验 + 日志扫描"的验证流水线。
#   3. 证书路径必须位于 mihomo 的 home（-d，即 /etc/mihomo）之下，否则 listener 静默失败。
set -Eeuo pipefail

MH_LIBDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
MH_ASSUME_YES=0
export MH_LIBDIR MH_ASSUME_YES

# ---------- 自举 ----------
# 用 `bash <(curl ...)` 或 `curl ... | sudo bash` 直接跑单文件时，脚本身边没有 lib/，
# 这里自动下载仓库压缩包到临时目录并前台重新执行（前台执行保证交互菜单还能读 stdin）。
MH_REPO_SLUG="${MH_REPO_SLUG:-Catbully/mihomo-vps}"
MH_REPO_BRANCH="${MH_REPO_BRANCH:-main}"
export MH_REPO_SLUG MH_REPO_BRANCH

bootstrap_self() {
  local tmp url rc=0 ok=0
  if ! command -v curl >/dev/null 2>&1; then
    printf '[E] E_BOOTSTRAP: 自举需要 curl\n' >&2
    exit 1
  fi
  if ! command -v tar >/dev/null 2>&1; then
    printf '[E] E_BOOTSTRAP: 自举需要 tar\n' >&2
    exit 1
  fi

  url="https://codeload.github.com/${MH_REPO_SLUG}/tar.gz/refs/heads/${MH_REPO_BRANCH}"
  tmp="$(mktemp -d)"
  printf '[*] 未找到 lib/ 目录，正在自举下载 %s@%s\n' "$MH_REPO_SLUG" "$MH_REPO_BRANCH" >&2

  # 先走镜像（若设置），失败再直连
  if [ -n "${MIHOMO_MIRROR:-}" ]; then
    if curl -fsSL --retry 2 --connect-timeout 15 --max-time 180 "${MIHOMO_MIRROR}${url}" |
      tar -xz -C "$tmp" --strip-components=1 2>/dev/null; then
      ok=1
    else
      rm -rf "$tmp"
      tmp="$(mktemp -d)"
    fi
  fi
  if [ "$ok" -eq 0 ]; then
    if curl -fsSL --retry 2 --connect-timeout 15 --max-time 180 "$url" |
      tar -xz -C "$tmp" --strip-components=1 2>/dev/null; then
      ok=1
    fi
  fi
  if [ "$ok" -eq 0 ]; then
    rm -rf "$tmp"
    {
      printf '[E] E_BOOTSTRAP: 下载仓库失败（%s）\n' "$url" >&2
      printf '  先确认本机 DNS 能用。若域名都解析不了，修完 DNS 再重试：\n' >&2
      printf '    cp -a /etc/resolv.conf /root/resolv.conf.bak 2>/dev/null || true\n' >&2
      printf '    printf "nameserver 1.1.1.1\\nnameserver 8.8.8.8\\n" > /etc/resolv.conf\n' >&2
      printf '  国内网络可设 MIHOMO_MIRROR=<镜像前缀>；用 fork 可设 MH_REPO_SLUG=<owner/repo>\n' >&2
    }
    exit 1
  fi
  if [ ! -f "$tmp/lib/common.sh" ]; then
    rm -rf "$tmp"
    printf '[E] E_BOOTSTRAP: 下载内容不完整（缺 lib/common.sh）\n' >&2
    exit 1
  fi

  bash "$tmp/mihomo.sh" "$@" || rc=$?
  rm -rf "$tmp"
  exit "$rc"
}

if [ ! -f "$MH_LIBDIR/common.sh" ]; then
  bootstrap_self "$@"
fi

# shellcheck source=lib/common.sh
. "$MH_LIBDIR/common.sh"
# shellcheck source=lib/detect.sh
. "$MH_LIBDIR/detect.sh"
# shellcheck source=lib/service.sh
. "$MH_LIBDIR/service.sh"
# shellcheck source=lib/render.sh
. "$MH_LIBDIR/render.sh"
# shellcheck source=lib/install.sh
. "$MH_LIBDIR/install.sh"
# shellcheck source=lib/users.sh
. "$MH_LIBDIR/users.sh"
# shellcheck source=lib/clients.sh
. "$MH_LIBDIR/clients.sh"
# shellcheck source=lib/forward.sh
. "$MH_LIBDIR/forward.sh"

trap 'die E_UNEXPECTED "第 ${LINENO} 行执行失败：${BASH_COMMAND}"' ERR
trap 'restore_dns' EXIT

# 只打印文件开头连续注释块，不写死行号（写死会在增删代码后把代码行当帮助输出）
usage() {
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"
}

interactive_menu() {
  local choice
  while true; do
    printf '\n%s=== mihomo 服务端管理 ===%s\n' "$C_BLU" "$C_OFF" >&2
    printf ' 1) 安装 / 重新配置\n' >&2
    printf ' 2) 修改协议与端口\n' >&2
    printf ' 3) 用户管理\n' >&2
    printf ' 4) 端口转发（nftables）\n' >&2
    printf ' 5) 输出配置（分享链接 + proxies）\n' >&2
    printf ' 6) 状态与诊断\n' >&2
    printf ' 7) 更新内核\n' >&2
    printf ' 8) 卸载\n' >&2
    printf ' 0) 退出\n' >&2
    choice="$(ask "请选择" "0")"
    case "$choice" in
      1) cmd_install ;;
      2) cmd_install ;;
      3) cmd_user_menu ;;
      4) cmd_forward_menu ;;
      5) cmd_clients --all ;;
      6) cmd_status ;;
      7) cmd_update ;;
      8) cmd_uninstall ;;
      0 | q | Q) return 0 ;;
      *) warn "无效选择：$choice" ;;
    esac
  done
}

main() {
  local cmd="${1:-}"
  [ $# -gt 0 ] && shift
  case "$cmd" in
    '' | menu) interactive_menu ;;
    install | reconfig) cmd_install "$@" ;;
    user) cmd_user "$@" ;;
    forward) cmd_forward "$@" ;;
    clients) cmd_clients "$@" ;;
    update) cmd_update "$@" ;;
    status) cmd_status "$@" ;;
    uninstall) cmd_uninstall "$@" ;;
    self-install) cmd_self_install ;;
    -h | --help | help) usage ;;
    *) die E_USAGE "未知命令：$cmd（用 --help 查看用法）" ;;
  esac
}

main "$@"
