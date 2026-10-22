#!/usr/bin/env bash
# shellcheck shell=bash
# nftables 端口转发。三种形态（Q28 全都要）：
#   dnat      ：本机端口 → 远端 host:port
#   redirect  ：本机端口 → 本机另一个端口
#   masquerade：默认开启，使回程也经本机（--no-masquerade 关闭）
#
# 落盘策略（Q41）：规则写在 /etc/mihomo/nft/forward.nft 的独立表 table inet mihomo，
# 由自带的 mihomo-nft.service 开机加载；绝不启用或改写系统的 nftables.service。

forward_init_db() {
  mkdir -p "$MH_NFT_DIR"
  chmod 700 "$MH_NFT_DIR"
  if [ ! -f "$MH_NFT_DB" ]; then
    printf '{"forwards":[]}\n' >"$MH_NFT_DB"
  fi
  chmod 600 "$MH_NFT_DB"
}

forward_render() {
  forward_init_db
  jq -r '
    def is6: (. | tostring | test(":"));
    "table inet mihomo",
    "delete table inet mihomo",
    "table inet mihomo {",
    "  chain prerouting {",
    "    type nat hook prerouting priority dstnat; policy accept;",
    ( .forwards[] | . as $f
      | if $f.mode == "redirect" then
          "    \($f.proto) dport \($f.listen_port) redirect to :\($f.target_port)"
        elif ($f.target_host | is6) then
          "    \($f.proto) dport \($f.listen_port) dnat ip6 to [\($f.target_host)]:\($f.target_port)"
        else
          "    \($f.proto) dport \($f.listen_port) dnat ip to \($f.target_host):\($f.target_port)"
        end ),
    "  }",
    "  chain postrouting {",
    "    type nat hook postrouting priority srcnat; policy accept;",
    ( .forwards[]
      | select(.masquerade == true and .mode != "redirect")
      | if (.target_host | is6) then
          "    ip6 daddr \(.target_host) \(.proto) dport \(.target_port) masquerade"
        else
          "    ip daddr \(.target_host) \(.proto) dport \(.target_port) masquerade"
        end ),
    "  }",
    "}"
  ' "$MH_NFT_DB" >"$MH_NFT_FILE" || die E_NFT "生成 nft 规则文件失败"
  chmod 600 "$MH_NFT_FILE"
}

forward_ensure_file() {
  forward_init_db
  forward_render
}

# DNAT 转发的前提：被改写目的地址的包要走 forward，ip_forward=0 时内核直接丢弃，
# 客户端表现为"端口能连上但数据永远回不来"。所以转发功能必须自己保证这两个开关。
MH_SYSCTL_FILE=/etc/sysctl.d/99-mihomo-forward.conf
export MH_SYSCTL_FILE

forward_ensure_forwarding() {
  local need_v6=0
  if [ -f "$MH_NFT_DB" ]; then
    if jq -e '.forwards[] | select(.mode != "redirect" and (.target_host | tostring | test(":")))' \
      "$MH_NFT_DB" >/dev/null 2>&1; then
      need_v6=1
    fi
  fi

  {
    printf '# 由 mihomo-vps 生成：nftables 端口转发需要转发能力\n'
    printf 'net.ipv4.ip_forward=1\n'
    if [ "$need_v6" = "1" ]; then
      printf 'net.ipv6.conf.all.forwarding=1\n'
    fi
  } >"$MH_SYSCTL_FILE"
  chmod 644 "$MH_SYSCTL_FILE"

  sysctl -q -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
  if [ "$need_v6" = "1" ]; then
    sysctl -q -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1 || true
  fi

  if [ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)" != "1" ]; then
    warn "无法开启 net.ipv4.ip_forward —— DNAT 转发不会生效（可能需要容器/宿主层授权）"
  fi
  if [ "$need_v6" = "1" ] && [ "$(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null || echo 0)" != "1" ]; then
    warn "无法开启 net.ipv6.conf.all.forwarding —— IPv6 目标的转发不会生效"
  fi
}
# 把规则真正加载进内核
forward_apply() {
  need_cmd nft
  if [ ! -f "$MH_NFT_FILE" ]; then
    forward_render
  fi

  if ! nft -f "$MH_NFT_FILE"; then
    die E_NFT "加载 nft 规则失败（检查 ${MH_NFT_FILE}）"
  fi
  forward_ensure_forwarding
  ok "nft 规则已生效（table inet mihomo）"
}

forward_count() {
  jq '.forwards | length' "$MH_NFT_DB"
}

forward_add() {
  local lport='' proto='tcp' to='' redirect='' masq='true'
  while [ $# -gt 0 ]; do
    case "$1" in
      --listen-port)
        lport="${2:-}"
        shift
        ;;
      --proto)
        proto="${2:-}"
        shift
        ;;
      --to)
        to="${2:-}"
        shift
        ;;
      --redirect-to)
        redirect="${2:-}"
        shift
        ;;
      --no-masquerade) masq='false' ;;
      --masquerade) masq='true' ;;
      *) die E_USAGE "forward add 不认识的参数：$1" ;;
    esac
    shift
  done

  if [ -z "$lport" ]; then
    lport="$(ask "监听端口" "$(rand_port)")"
    proto="$(ask "协议（tcp/udp）" "tcp")"
    to="$(ask "远端目标 host:port（留空则做本机端口重定向）" "")"
    if [ -z "$to" ]; then
      redirect="$(ask "本机重定向到哪个端口" "")"
    fi
  fi

  case "$proto" in
    tcp | udp) ;;
    *) die E_USAGE "--proto 只能是 tcp 或 udp" ;;
  esac
  case "$lport" in
    '' | *[!0-9]*) die E_USAGE "监听端口非法：$lport" ;;
  esac

  forward_init_db
  if [ "$(jq --argjson p "$lport" --arg pr "$proto" \
    '[.forwards[] | select(.listen_port == $p and .proto == $pr)] | length' "$MH_NFT_DB")" -gt 0 ]; then
    die E_FWD_DUP "$proto/$lport 的转发规则已存在"
  fi
  check_port_free "$lport" "$proto" "端口转发监听"

  if [ -n "$to" ]; then
    local thost tport
    case "$to" in
      \[*\]:*)
        thost="${to#\[}"
        thost="${thost%]:*}"
        tport="${to##*:}"
        ;;
      *:*)
        thost="${to%:*}"
        tport="${to##*:}"
        ;;
      *) die E_USAGE "目标格式应为 host:port（IPv6 用 [addr]:port）" ;;
    esac
    case "$tport" in
      '' | *[!0-9]*) die E_USAGE "目标端口非法：$tport" ;;
    esac
    jset "$MH_NFT_DB" --argjson p "$lport" --arg pr "$proto" \
      --arg h "$thost" --argjson tp "$tport" --argjson m "$masq" \
      '.forwards += [{ listen_port: $p, proto: $pr, mode: "dnat",
                       target_host: $h, target_port: $tp, masquerade: $m }]'
    ok "已添加：$proto/$lport → $thost:$tport（masquerade=$masq）"
  else
    case "$redirect" in
      '' | *[!0-9]*) die E_USAGE "本机重定向端口非法：$redirect" ;;
    esac
    jset "$MH_NFT_DB" --argjson p "$lport" --arg pr "$proto" --argjson tp "$redirect" \
      '.forwards += [{ listen_port: $p, proto: $pr, mode: "redirect",
                       target_port: $tp, masquerade: false }]'
    ok "已添加：$proto/$lport → 本机 :$redirect"
  fi

  forward_render
  forward_apply
}

forward_del() {
  local lport='' proto='tcp'
  while [ $# -gt 0 ]; do
    case "$1" in
      --listen-port)
        lport="${2:-}"
        shift
        ;;
      --proto)
        proto="${2:-}"
        shift
        ;;
      *) die E_USAGE "forward del 不认识的参数：$1" ;;
    esac
    shift
  done
  [ -n "$lport" ] || die E_USAGE "用法：forward del --listen-port <端口> [--proto tcp|udp]"
  json_require "$MH_NFT_DB"

  if [ "$(jq --argjson p "$lport" --arg pr "$proto" \
    '[.forwards[] | select(.listen_port == $p and .proto == $pr)] | length' "$MH_NFT_DB")" -eq 0 ]; then
    die E_FWD_NOTFOUND "没有匹配的规则：$proto/$lport"
  fi

  jset "$MH_NFT_DB" --argjson p "$lport" --arg pr "$proto" \
    '.forwards |= map(select((.listen_port == $p and .proto == $pr) | not))'
  forward_render
  forward_apply
  ok "已删除：$proto/$lport"
}

forward_flush() {
  json_require "$MH_NFT_DB"
  if [ "$(forward_count)" -eq 0 ]; then
    log "没有转发规则"
    return 0
  fi
  confirm_danger "将删除全部 $(forward_count) 条转发规则"
  jset "$MH_NFT_DB" '.forwards = []'
  forward_render
  forward_apply
  ok "已清空全部转发规则"
}

forward_list() {
  json_require "$MH_NFT_DB"
  if [ "$(forward_count)" -eq 0 ]; then
    log "没有转发规则"
  else
    printf '%-8s %-5s %-10s %s\n' "端口" "协议" "形态" "目标" >&2
    jq -r '.forwards[] |
      [ (.listen_port | tostring), .proto,
        (if .mode == "redirect" then "redirect" else "dnat" end),
        (if .mode == "redirect" then ("本机 :" + (.target_port | tostring))
         else (.target_host + ":" + (.target_port | tostring)
               + (if .masquerade then "  (masq)" else "" end)) end)
      ] | @tsv' "$MH_NFT_DB" |
      while IFS=$'\t' read -r p pr m t; do
        printf '%-8s %-5s %-10s %s\n' "$p" "$pr" "$m" "$t" >&2
      done
  fi

  if have_cmd nft && nft list table inet mihomo >/dev/null 2>&1; then
    log "内核中的实际规则（table inet mihomo）："
    nft list table inet mihomo >&2
  else
    warn "内核中没有 inet mihomo 表（规则未加载，用 forward apply 加载）"
  fi
}

forward_menu() {
  local c
  while true; do
    printf '\n%s端口转发%s\n' "$C_BLU" "$C_OFF" >&2
    printf ' 1) 列表  2) 新增  3) 删除  4) 清空  0) 返回\n' >&2
    c="$(ask "选择" "0")"
    case "$c" in
      1) forward_list ;;
      2) forward_add ;;
      3) forward_del ;;
      4) forward_flush ;;
      0 | q) return 0 ;;
      *) warn "无效选择：$c" ;;
    esac
  done
}

cmd_forward_menu() {
  forward_menu
}

cmd_forward() {
  local sub="${1:-list}"
  [ $# -gt 0 ] && shift
  need_root
  detect_system
  case "$sub" in
    add) forward_add "$@" ;;
    del | remove | rm) forward_del "$@" ;;
    list | ls) forward_list "$@" ;;
    flush) forward_flush "$@" ;;
    apply)
      forward_render
      forward_apply
      ;;
    menu) forward_menu ;;
    *) die E_USAGE "forward 子命令：add|del|list|flush|apply" ;;
  esac
}
