#!/usr/bin/env bash
# shellcheck shell=bash
# 多用户：用户是跨协议的一套身份。
#   * vless / vmess / trojan / hysteria2 / tuic 天然支持单 listener 多用户。
#   * shadowsocks 入站只有单个 password，因此每个需要 SS 的用户独占一个 listener/端口。

# 2022-blake3-aes-128-gcm 需要 16 字节密钥；sing 系实现接受带填充的 base64
ss_key_16() { head -c 16 /dev/urandom | base64 | tr -d '\n'; }

users_count() { jq '.users | length' "$MH_USERS"; }

user_exists() {
  [ "$(jq --arg n "$1" '[.users[] | select(.name == $n)] | length' "$MH_USERS")" -gt 0 ]
}

user_field() { # <name> <field>
  jq -r --arg n "$1" --arg f "$2" '.users[] | select(.name == $n) | .[$f] // ""' "$MH_USERS"
}

users_init() {
  if [ ! -f "$MH_USERS" ]; then
    printf '{"users":[]}\n' >"$MH_USERS"
    chmod 600 "$MH_USERS"
  fi
}

ensure_main_user() {
  users_init
  if [ "$(users_count)" -eq 0 ]; then
    log "创建主用户 main"
    users_add_internal "main" "yes"
  fi
  users_sync_main_ss
}

# 主用户的 SS 端口始终跟随 settings.protocols.ss.port；SS 关闭时清空其 ss 字段
users_sync_main_ss() {
  local en port
  en="$(jget '.protocols.ss.enabled' "$MH_SETTINGS")"
  if [ "$en" != "true" ]; then
    jset "$MH_USERS" '(.users[] | select(.name == "main") | .ss) = null'
    return 0
  fi
  port="$(jget '.protocols.ss.port' "$MH_SETTINGS")"
  jset "$MH_USERS" --argjson p "$port" --arg pw "$(ss_key_16)" '
    .users |= map(
      if .name == "main" then
        .ss = {
          port: $p,
          password: (if (.ss // {}) .password == null then $pw else .ss.password end)
        }
      else . end
    )'
}

users_add_internal() { # <name> <with_ss: yes|no>
  local name="$1" with_ss="${2:-no}" ss_port='' ss_obj='null'

  case "$name" in
    '' | *[!A-Za-z0-9_-]*) die E_USER "用户名只能用字母、数字、下划线、连字符：$name" ;;
  esac
  users_init
  if user_exists "$name"; then
    die E_USER "用户已存在：$name"
  fi
  if [ "$(users_count)" -ge "$MH_MAX_USERS" ]; then
    die E_USER "用户数已达上限（${MH_MAX_USERS}）"
  fi

  if [ "$with_ss" = "yes" ]; then
    if [ "$name" = "main" ]; then
      ss_port="$(jget '.protocols.ss.port' "$MH_SETTINGS")"
    else
      ss_port="$(rand_port)"
    fi
    ss_obj="$(jq -nc --argjson p "$ss_port" --arg w "$(ss_key_16)" '{port: $p, password: $w}')"
  fi

  jset "$MH_USERS" \
    --arg n "$name" \
    --arg u "$(random_uuid)" \
    --arg p "$(random_password)" \
    --argjson ss "$ss_obj" \
    '.users += [{ name: $n, uuid: $u, password: $p, enabled: true,
                  created: (now | todate), ss: $ss }]'

  ok "已添加用户：$name"
  if [ "$ss_obj" != "null" ]; then
    ok "  该用户的 Shadowsocks 独占端口：$ss_port"
  fi
}

users_remove_internal() { # <name>
  local name="$1"
  if ! user_exists "$name"; then
    die E_USER "用户不存在：$name"
  fi
  jset "$MH_USERS" --arg n "$name" '.users |= map(select(.name != $n))'
  ok "已删除用户：$name"
}

users_toggle_internal() { # <enable|disable> <name>
  local act="$1" name="$2" val
  if ! user_exists "$name"; then
    die E_USER "用户不存在：$name"
  fi
  case "$act" in
    enable) val=true ;;
    disable) val=false ;;
    *) die E_USAGE "toggle 只接受 enable/disable" ;;
  esac
  jset "$MH_USERS" --arg n "$name" --argjson v "$val" \
    '.users |= map(if .name == $n then .enabled = $v else . end)'
  ok "已 $act 用户：$name"
}

# ---------- 命令 ----------
ucmd_list() {
  json_require "$MH_USERS"
  printf '%-16s %-8s %-38s %-10s %s\n' "NAME" "ENABLED" "UUID" "SS端口" "创建时间" >&2
  jq -r '.users[] | [ .name, (if .enabled then "yes" else "no" end), .uuid,
        ((.ss.port // "-") | tostring), (.created // "-") ] | @tsv' "$MH_USERS" |
    while IFS=$'\t' read -r n e u p c; do
      printf '%-16s %-8s %-38s %-10s %s\n' "$n" "$e" "$u" "$p" "$c" >&2
    done
  log "共 $(users_count) 个用户，上限 ${MH_MAX_USERS}"
}

ucmd_show() {
  local name="${1:-}" uuid pw ssp sspw
  [ -n "$name" ] || die E_USAGE "用法：user show <名字>"
  json_require "$MH_USERS"
  user_exists "$name" || die E_USER "用户不存在：$name"
  uuid="$(user_field "$name" uuid)"
  pw="$(user_field "$name" password)"
  ssp="$(jq -r --arg n "$name" '.users[] | select(.name == $n) | .ss.port // ""' "$MH_USERS")"
  sspw="$(jq -r --arg n "$name" '.users[] | select(.name == $n) | .ss.password // ""' "$MH_USERS")"
  {
    printf '用户：%s\n' "$name"
    printf '  UUID      : %s\n' "$uuid"
    printf '  通用密码  : %s\n' "$pw"
    if [ -n "$ssp" ]; then
      printf '  SS 端口   : %s\n' "$ssp"
      printf '  SS 密码   : %s\n' "$sspw"
    else
      printf '  SS        : 未分配（用 user add <名字> --ss 分配独占端口）\n'
    fi
  } >&2
}

ucmd_add() {
  local name='' with_ss="no" arg
  for arg in "$@"; do
    case "$arg" in
      --ss) with_ss="yes" ;;
      --yes | -y)
        MH_ASSUME_YES=1
        export MH_ASSUME_YES
        ;;
      -*) die E_USAGE "未知参数：$arg" ;;
      *) name="$arg" ;;
    esac
  done
  json_require "$MH_SETTINGS"
  json_require "$MH_USERS"
  if [ -z "$name" ]; then
    name="$(ask "新用户名" "")"
  fi
  [ -n "$name" ] || die E_USER "用户名不能为空"

  users_add_internal "$name" "$with_ss"
  apply_config
  cmd_clients --user "$name"
}

ucmd_remove() {
  local name="${1:-}"
  [ -n "$name" ] || die E_USAGE "用法：user remove <名字>"
  json_require "$MH_USERS"
  if [ "$name" = "main" ]; then
    confirm_danger "删除主用户会让所有协议失去凭据来源，确认？"
  fi
  users_remove_internal "$name"
  rm -rf "${MH_CLIENTS:?}/$name"
  apply_config
}

ucmd_toggle() {
  local act="$1" name="${2:-}"
  [ -n "$name" ] || die E_USAGE "用法：user $act <名字>"
  json_require "$MH_USERS"
  users_toggle_internal "$act" "$name"
  apply_config
}

cmd_user_menu() {
  local c
  while true; do
    printf '\n%s用户管理%s\n' "$C_BLU" "$C_OFF" >&2
    printf ' 1) 列表  2) 新增  3) 删除  4) 查看凭据  5) 启用  6) 禁用  0) 返回\n' >&2
    c="$(ask "选择" "0")"
    case "$c" in
      1) ucmd_list ;;
      2) ucmd_add ;;
      3) ucmd_remove ;;
      4) ucmd_show ;;
      5) ucmd_toggle enable "$(ask "用户名" "")" ;;
      6) ucmd_toggle disable "$(ask "用户名" "")" ;;
      0 | q) return 0 ;;
      *) warn "无效选择：$c" ;;
    esac
  done
}

cmd_user() {
  local sub="${1:-list}"
  [ $# -gt 0 ] && shift
  need_root
  detect_system
  case "$sub" in
    add) ucmd_add "$@" ;;
    remove | rm | del) ucmd_remove "$@" ;;
    list | ls) ucmd_list "$@" ;;
    show) ucmd_show "$@" ;;
    export) cmd_clients --all ;;
    enable) ucmd_toggle enable "$@" ;;
    disable) ucmd_toggle disable "$@" ;;
    menu) cmd_user_menu ;;
    *) die E_USAGE "user 子命令：add|remove|list|show|export|enable|disable" ;;
  esac
}
