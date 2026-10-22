#!/usr/bin/env bash
# shellcheck shell=bash
# 配置渲染、校验与"真启动"验证流水线。
#
# 背景（实测）：mihomo -t 只做浅校验 —— 不读证书文件、不校验 REALITY/SS 密钥格式、
# 不检查 reality 与 certificate 互斥、不绑定端口。因此必须补上：
#   渲染 → mihomo -t → 重启 → 逐端口监听校验 → 日志扫描 → 失败回滚。

render_config() {
  json_require "$MH_SETTINGS"
  json_require "$MH_USERS"

  local tmp="$MH_CONFIG.tmp.$$"
  local errf="$MH_CONFIG.err.$$"
  if ! jq -f "$MH_LIBDIR/render.jq" --slurpfile users "$MH_USERS" "$MH_SETTINGS" >"$tmp" 2>"$errf"; then
    local msg
    msg="$(cat "$errf" 2>/dev/null || true)"
    rm -f "$tmp" "$errf"
    die E_RENDER "配置渲染失败：$msg"
  fi
  rm -f "$errf"

  local n
  n="$(jq '.listeners | length' "$tmp")"
  if [ "$n" -le 0 ]; then
    rm -f "$tmp"
    die E_RENDER "没有启用任何协议，拒绝生成空配置"
  fi

  chmod 600 "$tmp"
  mv -f "$tmp" "$MH_CONFIG"
}

test_config() {
  [ -x "$MH_BIN" ] || die E_NO_BINARY "找不到可执行的 mihomo：$MH_BIN"
  local out
  if ! out="$("$MH_BIN" -d "$MH_HOME" -t -f "$MH_CONFIG" 2>&1)"; then
    printf '%s\n' "$out" >&2
    return 1
  fi
  return 0
}

# expected_listeners：从渲染后的配置里推导"应当被监听的 协议 端口"清单
# shadowsocks 同时监听 TCP 与 UDP；hysteria2/tuic 是 QUIC（UDP）；其余为 TCP。
expected_listeners() {
  jq -r '
    .listeners[]
    | . as $l
    | (if (.type == "hysteria2" or .type == "tuic") then ["udp"]
       elif (.type == "shadowsocks") then ["tcp", "udp"]
       else ["tcp"] end)[]
    | "\(.) \($l.port|tostring)"
  ' "$MH_CONFIG"
}

listener_bound() { # <tcp|udp> <port>
  ss_port_bound "$2" "$1"
}

verify_listeners() {
  local fp=0 proto port logbad
  sleep 2

  while read -r proto port; do
    [ -n "${port:-}" ] || continue
    if ! listener_bound "$proto" "$port"; then
      warn "端口未监听：$proto/$port"
      fp=1
    fi
  done < <(expected_listeners)

  logbad="$(svc_recent_log '2 min ago' |
    grep -iE 'listen err|invalid private key|mutually exclusive|disallow using' || true)"
  if [ -n "$logbad" ]; then
    printf '%s\n' "$logbad" >&2
    fp=1
  fi

  [ "$fp" -eq 0 ]
}

# rollback_config <had_prev 0|1>
rollback_config() {
  local had_prev="${1:-0}"
  if [ -f "$MH_CONFIG" ]; then
    cp -a "$MH_CONFIG" "$MH_CONFIG.failed" 2>/dev/null || true
  fi
  if [ "$had_prev" = "1" ] && [ -f "$MH_CONFIG.prev" ]; then
    mv -f "$MH_CONFIG.prev" "$MH_CONFIG"
    warn "已回滚到上一份配置（失败的配置留在 ${MH_CONFIG}.failed）"
  else
    rm -f "$MH_CONFIG"
  fi
}

# apply_config：所有配置变更的唯一入口，含备份、校验、重启、验证与回滚
apply_config() {
  local had_prev=0
  backup_now >/dev/null 2>&1 || true
  if [ -f "$MH_CONFIG" ]; then
    cp -a "$MH_CONFIG" "$MH_CONFIG.prev"
    had_prev=1
  fi

  render_config

  if ! test_config; then
    rollback_config "$had_prev"
    die E_CONFIG_INVALID "mihomo -t 校验失败，配置已回滚"
  fi

  svc_restart || true

  if ! verify_listeners; then
    rollback_config "$had_prev"
    svc_restart || true
    die E_VERIFY "服务启动后监听校验失败，配置已回滚"
  fi

  rm -f "$MH_CONFIG.prev"
  ok "配置已生效，监听校验通过"
}
