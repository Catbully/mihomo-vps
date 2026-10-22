#!/usr/bin/env bash
# shellcheck shell=bash
# 客户端产物：proxies 片段、分享链接，可选完整配置与二维码。
# 默认只出片段 + 链接（Q15=A+C）；--full 才生成可直接运行的完整配置。

proto_on() { [ "$(jget ".protocols.$1.enabled" "$MH_SETTINGS")" = "true" ]; }
proto_port() { jget ".protocols.$1.port" "$MH_SETTINGS"; }

b64url() { base64 | tr -d '\n' | tr '+/' '-_' | tr -d '='; }

# 生成节点后是否把链接与 proxies 直接打到终端（MH_CLIENTS_QUIET=1 时静默）
MH_CLIENTS_QUIET=0

# print_client_output <name> <dir>：正文走 stdout（可重定向），标题走 stderr
print_client_output() {
  local name="$1" dir="$2"
  if [ "$MH_CLIENTS_QUIET" = "1" ]; then
    return 0
  fi
  printf '\n%s──────── 用户 %s 的分享链接（%s）────────%s\n' \
    "$C_BLU" "$name" "$dir/links.txt" "$C_OFF" >&2
  if [ -s "$dir/links.txt" ]; then
    cat "$dir/links.txt"
  else
    printf '(空)\n'
  fi
  printf '\n%s──────── 用户 %s 的 proxies 片段（%s）────────%s\n' \
    "$C_BLU" "$name" "$dir/proxies.yaml" "$C_OFF" >&2
  cat "$dir/proxies.yaml"
  if [ -f "$dir/client.yaml" ]; then
    printf '\n%s──────── 完整客户端配置（%s）────────%s\n' \
      "$C_BLU" "$dir/client.yaml" "$C_OFF" >&2
  fi
  printf '\n' >&2
}

# write_client_user <name> <full 0|1> [qr 0|1]
write_client_user() {
  local name="$1" full="${2:-0}" qr="${3:-0}"
  local dir uuid pw host sni cipher ssp sspw
  local -a names=()

  host="$(jget '.server_host' "$MH_SETTINGS")"
  sni="$(jget '.tls.sni' "$MH_SETTINGS")"
  cipher="$(jget '.protocols.ss.cipher' "$MH_SETTINGS")"
  uuid="$(user_field "$name" uuid)"
  pw="$(user_field "$name" password)"
  ssp="$(jq -r --arg n "$name" '.users[] | select(.name == $n) | .ss.port // ""' "$MH_USERS")"
  sspw="$(jq -r --arg n "$name" '.users[] | select(.name == $n) | .ss.password // ""' "$MH_USERS")"

  dir="$MH_CLIENTS/$name"
  mkdir -p "$dir"
  chmod 700 "$dir"
  printf 'proxies:\n' >"$dir/proxies.yaml"
  : >"$dir/links.txt"

  # ---- Shadowsocks-2022（独占端口）----
  if proto_on ss && [ -n "$ssp" ] && [ -n "$sspw" ]; then
    names+=("ss-$name")
    cat >>"$dir/proxies.yaml" <<EOF
  - name: "ss-$name"
    type: ss
    server: $host
    port: $ssp
    cipher: $cipher
    password: "$sspw"
    udp: true
EOF
    printf 'ss://%s@%s:%s#%s\n' \
      "$(printf '%s:%s' "$cipher" "$sspw" | b64url)" "$host" "$ssp" "ss-$name" >>"$dir/links.txt"
  fi

  # ---- VLESS + Vision + TLS ----
  if proto_on vless_tls; then
    names+=("vless-tls-$name")
    cat >>"$dir/proxies.yaml" <<EOF
  - name: "vless-tls-$name"
    type: vless
    server: $host
    port: $(proto_port vless_tls)
    uuid: $uuid
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: $sni
    skip-cert-verify: true
    client-fingerprint: chrome
EOF
    printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&fp=chrome&type=tcp&flow=xtls-rprx-vision&allowInsecure=1#%s\n' \
      "$uuid" "$host" "$(proto_port vless_tls)" "$sni" "vless-tls-$name" >>"$dir/links.txt"
  fi

  # ---- VLESS + REALITY ----
  if proto_on vless_reality; then
    local rpub rsid rsni
    rpub="$(jget '.protocols.vless_reality.public_key' "$MH_SETTINGS")"
    rsid="$(jget '.protocols.vless_reality.short_id[0] // ""' "$MH_SETTINGS")"
    rsni="$(jget '.protocols.vless_reality.server_names[0] // ""' "$MH_SETTINGS")"
    names+=("vless-reality-$name")
    cat >>"$dir/proxies.yaml" <<EOF
  - name: "vless-reality-$name"
    type: vless
    server: $host
    port: $(proto_port vless_reality)
    uuid: $uuid
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: $rsni
    client-fingerprint: chrome
    reality-opts:
      public-key: $rpub
      short-id: "$rsid"
EOF
    printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&flow=xtls-rprx-vision#%s\n' \
      "$uuid" "$host" "$(proto_port vless_reality)" "$rsni" "$rpub" "$rsid" "vless-reality-$name" >>"$dir/links.txt"
  fi

  # ---- Trojan ----
  if proto_on trojan; then
    names+=("trojan-$name")
    cat >>"$dir/proxies.yaml" <<EOF
  - name: "trojan-$name"
    type: trojan
    server: $host
    port: $(proto_port trojan)
    password: "$pw"
    sni: $sni
    skip-cert-verify: true
    udp: true
    client-fingerprint: chrome
EOF
    printf 'trojan://%s@%s:%s?security=tls&sni=%s&allowInsecure=1&type=tcp#%s\n' \
      "$pw" "$host" "$(proto_port trojan)" "$sni" "trojan-$name" >>"$dir/links.txt"
  fi

  # ---- VMess + WS + TLS ----
  if proto_on vmess; then
    local wpath
    wpath="$(jget '.protocols.vmess.ws_path' "$MH_SETTINGS")"
    names+=("vmess-ws-$name")
    cat >>"$dir/proxies.yaml" <<EOF
  - name: "vmess-ws-$name"
    type: vmess
    server: $host
    port: $(proto_port vmess)
    uuid: $uuid
    alterId: 0
    cipher: auto
    network: ws
    tls: true
    udp: true
    servername: $sni
    skip-cert-verify: true
    ws-opts:
      path: $wpath
EOF
    local vj
    vj="$(jq -nc --arg ps "vmess-ws-$name" --arg add "$host" \
      --argjson port "$(proto_port vmess)" --arg id "$uuid" \
      --arg snapath "$wpath" --arg sni "$sni" \
      '{v: "2", ps: $ps, add: $add, port: $port, id: $id, aid: "0", scy: "auto",
        net: "ws", type: "none", host: $sni, path: $snapath, tls: "tls", sni: $sni}')"
    printf 'vmess://%s\n' "$(printf '%s' "$vj" | base64 | tr -d '\n')" >>"$dir/links.txt"
  fi

  # ---- Hysteria2 ----
  if proto_on hysteria2; then
    local hobfs hobfspw
    hobfs="$(jget '.protocols.hysteria2.obfs // ""' "$MH_SETTINGS")"
    hobfspw="$(jget '.protocols.hysteria2.obfs_password // ""' "$MH_SETTINGS")"
    names+=("hysteria2-$name")
    cat >>"$dir/proxies.yaml" <<EOF
  - name: "hysteria2-$name"
    type: hysteria2
    server: $host
    port: $(proto_port hysteria2)
    password: "$pw"
    sni: $sni
    skip-cert-verify: true
EOF
    if [ -n "$hobfs" ]; then
      cat >>"$dir/proxies.yaml" <<EOF
    obfs: $hobfs
    obfs-password: "$hobfspw"
EOF
      printf 'hysteria2://%s@%s:%s?sni=%s&insecure=1&obfs=%s&obfs-password=%s#%s\n' \
        "$pw" "$host" "$(proto_port hysteria2)" "$sni" "$hobfs" "$hobfspw" "hysteria2-$name" >>"$dir/links.txt"
    else
      printf 'hysteria2://%s@%s:%s?sni=%s&insecure=1#%s\n' \
        "$pw" "$host" "$(proto_port hysteria2)" "$sni" "hysteria2-$name" >>"$dir/links.txt"
    fi
  fi

  # ---- Tuic ----
  if proto_on tuic; then
    names+=("tuic-$name")
    cat >>"$dir/proxies.yaml" <<EOF
  - name: "tuic-$name"
    type: tuic
    server: $host
    port: $(proto_port tuic)
    uuid: $uuid
    password: "$pw"
    alpn: [h3]
    sni: $sni
    skip-cert-verify: true
    congestion-controller: bbr
    udp-relay-mode: native
EOF
    printf 'tuic://%s:%s@%s:%s?congestion_control=bbr&alpn=h3&sni=%s&allow_insecure=1#%s\n' \
      "$uuid" "$pw" "$host" "$(proto_port tuic)" "$sni" "tuic-$name" >>"$dir/links.txt"
  fi

  if [ "${#names[@]}" -eq 0 ]; then
    rm -rf "$dir"
    warn "用户 $name 没有可用的协议凭据（SS 未分配且其它协议未启用）"
    return 0
  fi

  chmod 600 "$dir/proxies.yaml" "$dir/links.txt"

  if [ "$full" = "1" ]; then
    {
      printf 'mixed-port: 7890\nallow-lan: false\nmode: rule\nlog-level: info\n'
      cat "$dir/proxies.yaml"
      printf 'proxy-groups:\n  - name: PROXY\n    type: select\n    proxies:\n'
      local n
      for n in "${names[@]}"; do
        printf '      - "%s"\n' "$n"
      done
      printf 'rules:\n  - GEOIP,CN,DIRECT\n  - MATCH,PROXY\n'
    } >"$dir/client.yaml"
    chmod 600 "$dir/client.yaml"
  fi

  ok "用户 $name 的客户端产物：$dir（${#names[@]} 个节点）"
  print_client_output "$name" "$dir"
  if [ "$qr" = "1" ]; then
    if have_cmd qrencode; then
      while IFS= read -r link; do
        [ -n "$link" ] || continue
        qrencode -t ANSIUTF8 "$link" >&2 || true
      done <"$dir/links.txt"
    else
      warn "未安装 qrencode，跳过二维码（apt install qrencode / apk add libqrencode-tools）"
    fi
  fi
}

cmd_clients() {
  local all=0 user='' full=0 qr=0
  MH_CLIENTS_QUIET=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --all) all=1 ;;
      --user)
        user="${2:-}"
        shift
        ;;
      --full) full=1 ;;
      --qr) qr=1 ;;
      --no-print) MH_CLIENTS_QUIET=1 ;;
      *) die E_USAGE "clients 不认识的参数：$1" ;;
    esac
    shift
  done

  json_require "$MH_SETTINGS"
  json_require "$MH_USERS"
  mkdir -p "$MH_CLIENTS"
  chmod 700 "$MH_CLIENTS"

  if [ -n "$user" ]; then
    user_exists "$user" || die E_USER "用户不存在：$user"
    write_client_user "$user" "$full" "$qr"
    return 0
  fi

  if [ "$all" -eq 0 ]; then
    die E_USAGE "用法：clients --all | --user <名字> [--full] [--qr]"
  fi

  local n
  while read -r n; do
    [ -n "$n" ] || continue
    write_client_user "$n" "$full" "$qr"
  done < <(jq -r '.users[] | select(.enabled) | .name' "$MH_USERS")
  ok "客户端产物目录：$MH_CLIENTS"
}
