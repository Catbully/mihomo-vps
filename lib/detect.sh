#!/usr/bin/env bash
# shellcheck shell=bash
# 系统探测：发行版、架构、init 系统、依赖、网络与端口。

MH_OS_ID='unknown'
MH_OS_VER=''
MH_OS_FAMILY=''
MH_ARCH=''
MH_INIT=''

export MH_OS_ID MH_OS_VER MH_OS_FAMILY MH_ARCH MH_INIT

detect_system() {
  [ -r /etc/os-release ] || die E_UNSUPPORTED_OS "找不到 /etc/os-release，无法识别系统"
  # shellcheck disable=SC1091
  . /etc/os-release
  MH_OS_ID="${ID:-unknown}"
  MH_OS_VER="${VERSION_ID:-}"

  case "$MH_OS_ID" in
    debian)
      case "$MH_OS_VER" in
        12 | 13 | 14) MH_OS_FAMILY=debian ;;
        *) die E_UNSUPPORTED_OS "仅支持 Debian 12/13，当前：${MH_OS_VER}" ;;
      esac
      ;;
    ubuntu)
      case "$MH_OS_VER" in
        22.04 | 24.04) MH_OS_FAMILY=debian ;;
        *) die E_UNSUPPORTED_OS "仅支持 Ubuntu 22.04/24.04，当前：${MH_OS_VER}" ;;
      esac
      ;;
    alpine)
      case "$MH_OS_VER" in
        3.19* | 3.2[0-9]* | 3.[3-9][0-9]*) MH_OS_FAMILY=alpine ;;
        *) die E_UNSUPPORTED_OS "仅支持 Alpine 3.19+，当前：${MH_OS_VER}" ;;
      esac
      ;;
    *) die E_UNSUPPORTED_OS "不支持的发行版：$MH_OS_ID（仅 Debian/Ubuntu/Alpine）" ;;
  esac

  case "$(uname -m)" in
    x86_64 | amd64) MH_ARCH=amd64 ;;
    aarch64 | arm64) MH_ARCH=arm64 ;;
    *) die E_UNSUPPORTED_ARCH "不支持的架构：$(uname -m)（仅 amd64/arm64）" ;;
  esac

  if [ -d /run/systemd/system ] && have_cmd systemctl; then
    MH_INIT=systemd
  elif have_cmd rc-service; then
    MH_INIT=openrc
  else
    die E_UNSUPPORTED_INIT "既不是 systemd 也不是 OpenRC，脚本不接管"
  fi
}

# ensure_deps：按缺失项安装依赖，不做无谓的包管理操作
ensure_deps() {
  local need_pkg=0 bin pkg_list
  for bin in curl jq openssl tar gzip nft ss; do
    have_cmd "$bin" || need_pkg=1
  done
  if [ "$need_pkg" -eq 0 ]; then
    return 0
  fi

  case "$MH_OS_FAMILY" in
    debian) pkg_list="curl jq openssl ca-certificates tar gzip iproute2 nftables" ;;
    alpine) pkg_list="bash curl jq openssl ca-certificates tar gzip iproute2 nftables" ;;
    *) die E_UNSUPPORTED_OS "无法安装依赖：未知发行版族" ;;
  esac

  log "安装缺失依赖：$pkg_list"
  case "$MH_OS_FAMILY" in
    debian)
      DEBIAN_FRONTEND=noninteractive apt-get update -qq || die E_PKG "apt-get update 失败"
      # shellcheck disable=SC2086
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $pkg_list ||
        die E_PKG "apt-get install 失败"
      ;;
    alpine)
      # shellcheck disable=SC2086
      apk add --no-cache $pkg_list || die E_PKG "apk add 失败"
      ;;
  esac

  for bin in curl jq openssl tar gzip nft ss; do
    have_cmd "$bin" || die E_MISSING_CMD "依赖安装后仍缺少：$bin"
  done
}

# ---------- 网络 ----------
# net_check <url>：能发起一次 HTTPS 请求即视为 DNS 与出口正常
# net_check <url>：只要 TLS 握手与请求能发出就算网络正常。
# 注意不能用 curl -f：这里会拿到 404 之类的前缀地址，-f 会把"能连通"误判成"断网"。
net_check() {
  curl -sS -o /dev/null --connect-timeout 10 --max-time 20 "$1" >/dev/null 2>&1
}


# require_network：默认拒绝安装；--fix-dns 才临时补 DNS（先备份，可还原）
require_network() {
  if ! have_cmd curl; then
    warn "系统里没有 curl，无法做网络预检；将在依赖安装阶段补上"
    return 0
  fi

  if net_check "$MH_GITHUB_DL" || net_check "$MH_GITHUB_API"; then
    return 0
  fi

  warn "无法访问 GitHub：DNS 或出口异常"
  if [ -r /etc/resolv.conf ]; then
    warn "当前 /etc/resolv.conf 的 nameserver：$(awk '/^nameserver/{printf "%s ", $2}' /etc/resolv.conf)"
  fi

  if [ "${MH_FIX_DNS:-0}" != "1" ]; then
    die E_DNS_BROKEN "网络不可用。修复命令示例：
  cp /etc/resolv.conf /etc/resolv.conf.bak
  echo 'nameserver 1.1.1.1' > /etc/resolv.conf
或重跑：$0 install --fix-dns（会先备份 /etc/resolv.conf，并在退出时还原）"
  fi

  local bak
  local bak
  bak="/etc/resolv.conf.bak-$(date +%Y%m%d-%H%M%S)"
  cp -a /etc/resolv.conf "$bak" || die E_DNS_BROKEN "备份 /etc/resolv.conf 失败"
  # 8.8.8.8 在国内/部分机房被墙或丢包，实测常有超时，所以用 1.1.1.1 + 223.5.5.5
  printf 'nameserver 1.1.1.1\nnameserver 223.5.5.5\n' >/etc/resolv.conf
  MH_DNS_BACKUP="$bak"
  export MH_DNS_BACKUP
  warn "已临时写入 1.1.1.1/223.5.5.5，原文件备份在 $bak"

  # 关键：DHCP 机器上 dhclient 续租时会按 provider 下发的 option 重写 resolv.conf，
  # 手改的内容会被覆盖回去。加一条 supersede 才算持久修，否则装完过一阵又坏。
  if have_cmd dhclient && [ -f /etc/dhcp/dhclient.conf ] &&
    ! grep -q 'mihomo-vps' /etc/dhcp/dhclient.conf; then
    cp -a /etc/dhcp/dhclient.conf "/etc/dhcp/dhclient.conf.bak-$(date +%Y%m%d-%H%M%S)"
    {
      printf '\n# 由 mihomo-vps 添加：避免 DHCP 续租把解析器改回不可用地址\n'
      printf 'supersede domain-name-servers 1.1.1.1, 223.5.5.5;\n'
    } >>/etc/dhcp/dhclient.conf
    warn "已给 dhclient 加 supersede（下次续租起生效），原配置已备份"
  fi
  net_check "$MH_GITHUB_DL" || die E_DNS_BROKEN "修正 DNS 后仍无法访问 GitHub，放弃安装"
}

# restore_dns：退出时还原被 --fix-dns 改动的 resolv.conf
restore_dns() {
  if [ -n "${MH_DNS_BACKUP:-}" ] && [ -f "$MH_DNS_BACKUP" ]; then
    cp -a "$MH_DNS_BACKUP" /etc/resolv.conf && warn "已还原 /etc/resolv.conf（备份：$MH_DNS_BACKUP）"
    MH_DNS_BACKUP=''
  fi
}

fetch() {
  local url="$1"
  if [ -n "$MH_MIRROR" ]; then
    if ! curl -fsSL --retry 2 --connect-timeout 15 --max-time 300 "${MH_MIRROR}${url}"; then
      curl -fsSL --retry 2 --connect-timeout 15 --max-time 300 "$url"
    fi
  else
    curl -fsSL --retry 2 --connect-timeout 15 --max-time 300 "$url"
  fi
}

# ---------- REALITY ----------
# reality_dest_ok <dest>：REALITY 服务端要主动连接 dest（伪装目标）完成握手，
# 所以本机必须能解析它、也能连通它的端口。解析不了时现象是"连上即 EOF/连接被重置"，
# 而 mihomo -t 与端口校验都看不出来 —— 只能这样单独验。
reality_dest_ok() {
  local dest="${1:-}" host port
  case "$dest" in
    '' ) return 1 ;;
    \[*\]:* )
      host="${dest#\[}"
      host="${host%]:*}"
      port="${dest##*:}"
      ;;
    *:* )
      host="${dest%:*}"
      port="${dest##*:}"
      ;;
    * )
      host="$dest"
      port=443
      ;;
  esac

  # 域名才需要解析；IP 字面量跳过这一步
  case "$host" in
    *[!0-9.]*)
      if have_cmd getent; then
        getent ahostsv4 "$host" >/dev/null 2>&1 || return 1
      else
        nslookup_ok "$host" || return 1
      fi
      ;;
  esac

  if have_cmd timeout; then
    timeout 8 bash -c "exec 3<>/dev/tcp/${host}/${port}" >/dev/null 2>&1
  else
    bash -c "exec 3<>/dev/tcp/${host}/${port}" >/dev/null 2>&1
  fi
}

# 没有 getent 时的域名解析兜底（Alpine busybox 可能缺 getent）
nslookup_ok() {
  if have_cmd nslookup; then
    nslookup "$1" >/dev/null 2>&1
  else
    curl -sS -o /dev/null --connect-timeout 8 --max-time 8 "https://$1" >/dev/null 2>&1
  fi
}

# ---------- 地址与端口 ----------
# public_v4：取第一个全局 IPv4，作为客户端连接的服务器地址默认值
public_v4() {
  local ip=''
  if have_cmd ip; then
    ip="$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | sed -n 1p)"
  fi
  printf '%s\n' "$ip"
}

# has_ipv6：有全局 IPv6 地址且存在 IPv6 默认路由
has_ipv6() {
  have_cmd ip || return 1
  local addr route
  addr="$(ip -6 addr show scope global 2>/dev/null || true)"
  route="$(ip -6 route show default 2>/dev/null || true)"
  case "$addr" in
    *inet6*) ;;
    *) return 1 ;;
  esac
  case "$route" in
    *default*) return 0 ;;
    *) return 1 ;;
  esac
}

# ss_port_bound <port> <tcp|udp>：该端口是否已在监听。
# 刻意不用 `ss | awk | grep -q`：在 set -o pipefail 下，grep -q 提前退出会让上游
# 收到 SIGPIPE（退出码 141），把"命中"误判成"未命中"。
ss_port_bound() {
  local port="${1:-}" proto="${2:-tcp}" flag out line
  case "$proto" in
    tcp) flag=t ;;
    udp) flag=u ;;
    *) return 1 ;;
  esac
  have_cmd ss || return 1
  out="$(ss -Hln"$flag" 2>/dev/null | awk '{print $4}')" || return 1
  while IFS= read -r line; do
    case "$line" in
      *":${port}" | *".${port}") return 0 ;;
    esac
  done <<<"$out"
  return 1
}

port_in_use() { ss_port_bound "$1" "${2:-tcp}"; }

# check_port_free <port> <tcp|udp> <用途说明>
check_port_free() {
  local port="$1" proto="${2:-tcp}" what="${3:-服务}"
  case "$port" in
    '' | *[!0-9]*) die E_USAGE "端口非法：$port" ;;
  esac
  [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || die E_USAGE "端口越界：$port"
  if port_in_use "$port" "$proto"; then
    die E_PORT_IN_USE "$proto/$port 已被占用（$what）"
  fi
}
