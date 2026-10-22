#!/usr/bin/env bash
# shellcheck shell=bash
# 安装、重配、更新、卸载与状态诊断。

# ---------- 内核下载与安装 ----------
mihomo_latest_tag() {
  local tag=''
  tag="$(fetch "$MH_GITHUB_API" 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null || true)"
  [ -n "$tag" ] || die E_GITHUB "无法获取 mihomo 最新版本（可设置 MIHOMO_MIRROR 走镜像前缀）"
  printf '%s\n' "$tag"
}

mihomo_asset() { # <arch> <tag>
  if [ "$1" = "amd64" ]; then
    printf 'mihomo-linux-amd64-compatible-%s.gz\n' "$2"
  else
    printf 'mihomo-linux-%s-%s.gz\n' "$1" "$2"
  fi
}

install_binary() { # [tag]
  local tag="${1:-}" asset tmpdir bak gotver rawver
  [ -n "$tag" ] || tag="$(mihomo_latest_tag)"
  asset="$(mihomo_asset "$MH_ARCH" "$tag")"
  tmpdir="$(mktemp -d)"

  log "下载 ${asset}（${tag}）"
  if ! fetch "$MH_GITHUB_DL/$tag/$asset" >"$tmpdir/m.gz" 2>/dev/null; then
    if [ "$MH_ARCH" = "amd64" ]; then
      asset="mihomo-linux-amd64-${tag}.gz"
      log "compatible 变体不可用，回退 ${asset}"
      if ! fetch "$MH_GITHUB_DL/$tag/$asset" >"$tmpdir/m.gz" 2>/dev/null; then
        rm -rf "$tmpdir"
        die E_DOWNLOAD "下载失败：$asset（检查网络，或设置 MIHOMO_MIRROR）"
      fi
    else
      rm -rf "$tmpdir"
      die E_DOWNLOAD "下载失败：$asset（检查网络，或设置 MIHOMO_MIRROR）"
    fi
  fi

  if ! gunzip -c "$tmpdir/m.gz" >"$tmpdir/mihomo" 2>/dev/null; then
    rm -rf "$tmpdir"
    die E_DOWNLOAD "解压失败，可能下载到了错误页而非二进制"
  fi
  chmod 0755 "$tmpdir/mihomo"

  # 注意：不要写成 `mihomo -v | head -1` —— pipefail 下 head 提前关闭管道会让
  # mihomo 收到 SIGPIPE（退出码 141），从而被误判为"二进制不可执行"。
  if ! rawver="$("$tmpdir/mihomo" -v 2>/dev/null)"; then
    rm -rf "$tmpdir"
    die E_BINARY "下载的二进制无法执行（架构不匹配？）"
  fi
  gotver="$(printf '%s\n' "$rawver" | sed -n 1p)"

  if [ -f "$MH_BIN" ]; then
    bak="$MH_BIN.bak-$(date +%Y%m%d-%H%M%S)"
    cp -a "$MH_BIN" "$bak" || true
    log "旧内核已备份：$bak"
  fi

  install -m 0755 "$tmpdir/mihomo" "$MH_BIN" || {
    rm -rf "$tmpdir"
    die E_BINARY "安装到 $MH_BIN 失败"
  }
  rm -rf "$tmpdir"
  ok "内核就绪：$gotver"
}

# ---------- 证书 ----------
gen_self_signed() { # <cn>
  local cn="$1" tmpd
  tmpd="$(mktemp -d)"
  mkdir -p "$MH_CERTS"
  chmod 700 "$MH_CERTS"

  if ! openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$tmpd/privkey.pem" -out "$tmpd/fullchain.pem" \
    -subj "/CN=$cn" -addext "subjectAltName=DNS:$cn" >/dev/null 2>&1; then
    # 老版本 openssl 不支持 -addext 时退化为不带 SAN
    if ! openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
      -keyout "$tmpd/privkey.pem" -out "$tmpd/fullchain.pem" \
      -subj "/CN=$cn" >/dev/null 2>&1; then
      rm -rf "$tmpd"
      die E_CERT "自签证书生成失败（openssl 不可用？）"
    fi
  fi

  install -m 600 "$tmpd/privkey.pem" "$MH_CERTS/privkey.pem"
  install -m 644 "$tmpd/fullchain.pem" "$MH_CERTS/fullchain.pem"
  rm -rf "$tmpd"
  ok "已生成自签证书 CN=$cn（10 年有效）"
}

import_cert() { # <cert> <key>
  local c="$1" k="$2"
  [ -r "$c" ] || die E_CERT "证书不可读：$c"
  [ -r "$k" ] || die E_CERT "私钥不可读：$k"
  openssl x509 -in "$c" -noout >/dev/null 2>&1 || die E_CERT "证书格式无法解析：$c"
  mkdir -p "$MH_CERTS"
  chmod 700 "$MH_CERTS"
  install -m 644 "$c" "$MH_CERTS/fullchain.pem"
  install -m 600 "$k" "$MH_CERTS/privkey.pem"
  ok "已导入证书（来源 $c），按 mihomo 要求复制进 ${MH_HOME}/certs/"
}

# ---------- REALITY 密钥 ----------
ensure_reality_keys() {
  local need priv out pk pb
  need="$(jget '.protocols.vless_reality.enabled // false' "$MH_SETTINGS")"
  [ "$need" = "true" ] || return 0

  priv="$(jget '.protocols.vless_reality.private_key // ""' "$MH_SETTINGS")"
  if [ -n "$priv" ]; then
    return 0
  fi

  [ -x "$MH_BIN" ] || die E_NO_BINARY "生成 REALITY 密钥前需要先安装内核"
  out="$("$MH_BIN" generate reality-keypair 2>/dev/null)" ||
    die E_REALITY "内核不支持 generate reality-keypair"
  pk="$(printf '%s\n' "$out" | awk -F': *' '/PrivateKey/{print $2; exit}')"
  pb="$(printf '%s\n' "$out" | awk -F': *' '/PublicKey/{print $2; exit}')"
  [ -n "$pk" ] && [ -n "$pb" ] || die E_REALITY "解析 REALITY 密钥失败：$out"

  # 官方输出是 43 字符 base64url 无填充；补 '=' 会导致运行时 illegal base64 data
  jset "$MH_SETTINGS" --arg pk "$pk" --arg pb "$pb" \
    '.protocols.vless_reality.private_key = $pk | .protocols.vless_reality.public_key = $pb'
  ok "已生成 REALITY 密钥对"
}

# ---------- 安装向导 ----------
# 向导内的端口选择。注意：不能用命令替换取值 —— 命令替换在子 shell 里执行，
# "本次已用端口"的累积会丢失，从而让两个协议抽到同一个端口。
MH_WIZ_USED=' '
MH_WIZ_PORT=''

wiz_ask_port() { # <提示>；结果写入全局 MH_WIZ_PORT
  local p
  while true; do
    p="$(ask "$1" "$(rand_port)")"
    case "$p" in
      '' | *[!0-9]*) die E_USAGE "端口非法：$p" ;;
    esac
    if [ "$p" -lt 1 ] || [ "$p" -gt 65535 ]; then
      die E_USAGE "端口越界：$p"
    fi
    case "$MH_WIZ_USED" in
      *" $p "*)
        if [ "$MH_ASSUME_YES" = "1" ]; then
          warn "端口 $p 本次已用，自动重抽"
          continue
        fi
        die E_PORT_DUP "端口 $p 已被本次选择的其它协议占用"
        ;;
    esac
    MH_WIZ_USED="$MH_WIZ_USED$p "
    MH_WIZ_PORT="$p"
    return 0
  done
}

wizard_settings() {
  local listen server_host log_level sni tls_mode sel n need_cert
  local pick_ss=0 pick_vless_tls=0 pick_reality=0 pick_trojan=0 pick_vmess=0 pick_hy2=0 pick_tuic=0
  local p_ss=0 p_vless_tls=0 p_reality=0 p_trojan=0 p_vmess=0 p_hy2=0 p_tuic=0
  local hy2_obfs='' hy2_obfs_pw='' ws_path='' rdest='' rshort='' rsn=''
  local old_priv='' dns_up='' dns_srv=''
  MH_WIZ_USED=' '

  printf '\n%s可选协议%s\n' "$C_BLU" "$C_OFF" >&2
  printf '  1) Shadowsocks-2022（TCP+UDP，单密码，每用户独立端口）\n' >&2
  printf '  2) VLESS + Vision + TLS\n' >&2
  printf '  3) VLESS + REALITY（无需证书，抗封锁更好）\n' >&2
  printf '  4) Trojan + TLS\n' >&2
  printf '  5) VMess + WS + TLS\n' >&2
  printf '  6) Hysteria2（QUIC/UDP，弱网表现好）\n' >&2
  printf '  7) Tuic（QUIC/UDP）\n' >&2
  printf '预设：lite = 1,6    full = 1,2,3,4,5,6,7\n\n' >&2

  sel="$(ask "选择协议（编号，空格/逗号分隔，或 lite/full）" "lite")"
  sel="$(printf '%s' "$sel" | tr ',' ' ')"
  case "$sel" in
    lite) sel="1 6" ;;
    full) sel="1 2 3 4 5 6 7" ;;
  esac
  for n in $sel; do
    case "$n" in
      1) pick_ss=1 ;;
      2) pick_vless_tls=1 ;;
      3) pick_reality=1 ;;
      4) pick_trojan=1 ;;
      5) pick_vmess=1 ;;
      6) pick_hy2=1 ;;
      7) pick_tuic=1 ;;
      *) die E_USAGE "未知协议编号：$n" ;;
    esac
  done
  need_cert=$((pick_vless_tls + pick_trojan + pick_vmess + pick_hy2 + pick_tuic))
  [ $((pick_ss + need_cert + pick_reality)) -gt 0 ] || die E_USAGE "至少选择一个协议"

  listen="$(ask "监听地址" "0.0.0.0")"
  if [ "$listen" = "::" ] && ! has_ipv6; then
    warn "本机没有可用的 IPv6 默认路由，退回 0.0.0.0"
    listen="0.0.0.0"
  fi
  server_host="$(ask "客户端连接的服务器地址（域名或 IP）" "$(public_v4)")"
  [ -n "$server_host" ] || die E_USAGE "服务器地址不能为空"
  log_level="$(ask "日志级别（silent/error/warning/info/debug）" "info")"
  dns_up="$(ask "DNS 上游（逗号分隔；服务端解析被代理域名用，与 /etc/resolv.conf 无关）" "1.1.1.1,223.5.5.5,9.9.9.9")"
  dns_srv="$(printf '%s' "$dns_up" |
    jq -Rc 'split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))')"
  [ "$(printf '%s' "$dns_srv" | jq 'length')" -gt 0 ] ||
    die E_USAGE "DNS 上游不能为空"

  if [ "$pick_ss" = 1 ]; then
    wiz_ask_port "Shadowsocks 端口（TCP+UDP）"
    p_ss="$MH_WIZ_PORT"
  fi
  if [ "$pick_vless_tls" = 1 ]; then
    wiz_ask_port "VLESS+Vision+TLS 端口（TCP）"
    p_vless_tls="$MH_WIZ_PORT"
  fi
  if [ "$pick_reality" = 1 ]; then
    wiz_ask_port "VLESS+REALITY 端口（TCP）"
    p_reality="$MH_WIZ_PORT"
  fi
  if [ "$pick_trojan" = 1 ]; then
    wiz_ask_port "Trojan 端口（TCP）"
    p_trojan="$MH_WIZ_PORT"
  fi
  if [ "$pick_vmess" = 1 ]; then
    wiz_ask_port "VMess+WS+TLS 端口（TCP）"
    p_vmess="$MH_WIZ_PORT"
  fi
  if [ "$pick_hy2" = 1 ]; then
    wiz_ask_port "Hysteria2 端口（UDP）"
    p_hy2="$MH_WIZ_PORT"
  fi
  if [ "$pick_tuic" = 1 ]; then
    wiz_ask_port "Tuic 端口（UDP）"
    p_tuic="$MH_WIZ_PORT"
  fi

  if [ "$pick_hy2" = 1 ]; then
    if ask_yn "启用 Hysteria2 salamander 混淆" "y"; then
      hy2_obfs="salamander"
      hy2_obfs_pw="$(random_b64 12)"
    fi
  fi

  if [ "$pick_vmess" = 1 ]; then
    ws_path="$(ask "VMess WebSocket 路径（只有 path，mihomo 不支持自定义 header）" "/$(random_hex 8)")"
  fi

  if [ "$pick_reality" = 1 ]; then
    rdest="$(ask "REALITY 伪装目标 dest（需支持 TLS1.3 + h2）" "$MH_REALITY_DEST_DEFAULT")"
    rsn="$(ask "REALITY server-names（必须包含 dest 的域名）" "${rdest%:*}")"
    rshort="$(random_hex 8)"
    case ",${rsn// /,}," in
      *",${rdest%:*},") ;;
      *) die E_REALITY "server-names（$rsn）必须包含 dest 域名（${rdest%:*}），否则 REALITY 会随机断连" ;;
    esac
    if ! reality_dest_ok "$rdest"; then
      warn "REALITY dest（$rdest）在本机无法解析或连不通 —— REALITY 会表现为『连上即断』"
      warn "请先修好本机 DNS/出站；装完修好后再 systemctl restart mihomo 才会生效"
    fi
  fi

  sni="$(ask "证书 CN/SNI（自签时随便填个域名）" "mihomo.local")"
  if [ "$need_cert" -gt 0 ]; then
    tls_mode="$(ask "证书来源（selfsigned=自签 / import=导入已有证书）" "selfsigned")"
    case "$tls_mode" in
      import)
        local cpath kpath
        cpath="$(ask "已有证书路径（PEM/crt）" "")"
        kpath="$(ask "对应私钥路径（PEM/key）" "")"
        import_cert "$cpath" "$kpath"
        tls_mode="import"
        ;;
      *) tls_mode="selfsigned" ;;
    esac
  else
    tls_mode="none"
  fi

  if [ -f "$MH_SETTINGS" ]; then
    old_priv="$(jget '.protocols.vless_reality.private_key // ""' "$MH_SETTINGS" 2>/dev/null || true)"
  fi

  jq -n \
    --arg listen "$listen" --arg server_host "$server_host" --arg log_level "$log_level" \
    --argjson dns_srv "$dns_srv" \
    --arg tls_mode "$tls_mode" --arg cert "$MH_CERTS/fullchain.pem" \
    --arg key "$MH_CERTS/privkey.pem" --arg sni "$sni" \
    --argjson ss_e "$pick_ss" --argjson ss_p "$p_ss" \
    --argjson vlt_e "$pick_vless_tls" --argjson vlt_p "$p_vless_tls" \
    --argjson vr_e "$pick_reality" --argjson vr_p "$p_reality" \
    --arg vr_dest "$rdest" --arg vr_sid "$rshort" \
    --arg vr_net "$rsn" \
    --argjson tj_e "$pick_trojan" --argjson tj_p "$p_trojan" \
    --argjson vm_e "$pick_vmess" --argjson vm_p "$p_vmess" --arg vm_ws "$ws_path" \
    --argjson hy_e "$pick_hy2" --argjson hy_p "$p_hy2" \
    --arg hy_obfs "$hy2_obfs" --arg hy_obfspw "$hy2_obfs_pw" \
    --argjson tu_e "$pick_tuic" --argjson tu_p "$p_tuic" \
    '{
      listen: $listen,
      server_host: $server_host,
      log_level: $log_level,
      dns: { nameserver: $dns_srv, default_nameserver: ($dns_srv[0:2]) },
      tls: { mode: $tls_mode, cert: $cert, key: $key, sni: $sni },
      protocols: {
        ss:            { enabled: ($ss_e == 1),  port: $ss_p,   cipher: "2022-blake3-aes-128-gcm" },
        vless_tls:     { enabled: ($vlt_e == 1), port: $vlt_p },
        vless_reality: { enabled: ($vr_e == 1),  port: $vr_p,   dest: $vr_dest,
                         private_key: "", public_key: "",
                         short_id: (if $vr_sid == "" then [] else [$vr_sid] end),
                         server_names: (if $vr_net == "" then [] else [$vr_net] end) },
        trojan:        { enabled: ($tj_e == 1),  port: $tj_p },
        vmess:         { enabled: ($vm_e == 1),  port: $vm_p,   ws_path: $vm_ws },
        hysteria2:     { enabled: ($hy_e == 1),  port: $hy_p,
                         obfs: $hy_obfs, obfs_password: $hy_obfspw },
        tuic:          { enabled: ($tu_e == 1),  port: $tu_p }
      }
    }' >"$MH_SETTINGS" || die E_JSON "写入 $MH_SETTINGS 失败"
  chmod 600 "$MH_SETTINGS"

  if [ -n "$old_priv" ]; then
    jset "$MH_SETTINGS" --arg pk "$old_priv" '.protocols.vless_reality.private_key = $pk'
  fi

  if [ "$tls_mode" = "selfsigned" ]; then
    gen_self_signed "$sni"
  fi

  check_settings_ports
  ok "配置已记录到 $MH_SETTINGS"
}

# 端口唯一性与占用检查（服务已停，不会误判自己）
check_settings_ports() {
  local proto port seen=' '
  while IFS=' ' read -r proto port; do
    [ -n "${port:-}" ] || continue
    if [ "$port" = "0" ]; then
      continue
    fi
    case "$seen" in
      *" $proto:$port "*) die E_PORT_DUP "$proto/$port 被重复占用" ;;
    esac
    seen="$seen$proto:$port "
    check_port_free "$port" "$proto" "安装前检查"
  done < <(settings_ports)
}

# settings_ports：从 settings.json 推导"协议 端口"
settings_ports() {
  jq -r '
    .protocols
    | to_entries[]
    | select(.value.enabled == true)
    | .key as $k
    | .value.port as $p
    | (if ($k == "hysteria2" or $k == "tuic") then ["udp"]
       elif ($k == "ss") then ["tcp", "udp"]
       else ["tcp"] end)[]
    | "\(.) \($p)"
  ' "$MH_SETTINGS"
}

# ---------- 主流程 ----------
# ---------- 把脚本自身落地 + 提供常驻管理命令 ----------
# 注意：/usr/local/bin/mihomo 是 mihomo 内核本身（systemd 单元启的就是它），
# 绝不能用 "mihomo" 命名菜单命令，否则会顶掉内核。这里用 mihomo-vps。
MH_INSTALL_DIR=/usr/local/lib/mihomo-vps
MH_CMD=/usr/local/bin/mihomo-vps
export MH_INSTALL_DIR MH_CMD

install_self() {
  local src_dir f
  src_dir="$(cd "$MH_LIBDIR/.." && pwd)"
  if [ "$src_dir" = "$MH_INSTALL_DIR" ]; then
    log "脚本已在 $MH_INSTALL_DIR，跳过自安装"
    return 0
  fi

  mkdir -p "$MH_INSTALL_DIR/lib"
  install -m 0644 "$src_dir/mihomo.sh" "$MH_INSTALL_DIR/mihomo.sh" ||
    die E_SELF "复制 mihomo.sh 到 $MH_INSTALL_DIR 失败"
  for f in "$src_dir"/lib/*.sh "$src_dir"/lib/*.jq; do
    [ -f "$f" ] || continue
    install -m 0644 "$f" "$MH_INSTALL_DIR/lib/$(basename "$f")" ||
      die E_SELF "复制 $(basename "$f") 失败"
  done
  if [ -f "$src_dir/README.md" ]; then
    install -m 0644 "$src_dir/README.md" "$MH_INSTALL_DIR/README.md"
  fi

  cat >"$MH_CMD" <<EOF
#!/bin/sh
# 由 mihomo-vps 安装脚本生成：打开 mihomo 服务端管理菜单
exec bash ${MH_INSTALL_DIR}/mihomo.sh "\$@"
EOF
  chmod 0755 "$MH_CMD"
  ok "已安装管理命令：${MH_CMD}（脚本落地在 ${MH_INSTALL_DIR}）"
}

cmd_self_install() {
  need_root
  install_self
  log "现在可以直接运行：mihomo-vps"
}
cmd_install() {
  local arg
  MH_ASSUME_YES=0
  export MH_ASSUME_YES
  for arg in "$@"; do
    case "$arg" in
      --yes | -y)
        MH_ASSUME_YES=1
        export MH_ASSUME_YES
        ;;
      --fix-dns)
        MH_FIX_DNS=1
        export MH_FIX_DNS
        ;;
      *) die E_USAGE "install 不认识的参数：$arg" ;;
    esac
  done

  need_root
  detect_system
  require_network
  ensure_deps
  ensure_dirs

  if svc_is_active 2>/dev/null; then
    log "停止已运行的服务以便检查端口"
    svc_stop || true
    sleep 1
  fi

  wizard_settings
  install_binary "${MH_TAG:-}"
  ensure_main_user
  ensure_reality_keys
  svc_install_units
  svc_nft_install_units
  forward_ensure_file
  apply_config
  svc_enable
  svc_nft_enable
  svc_nft_reload

  install_self

  restore_dns
  ok "安装完成"
  cmd_clients --all
  cmd_status
  printf '\n' >&2
  ok "以后随时用 ${MH_CMD} 打开管理菜单（等价于 bash ${MH_INSTALL_DIR}/mihomo.sh）"
}

cmd_update() {
  need_root
  detect_system
  require_network
  install_binary "${1:-}"
  svc_restart
  if ! verify_listeners; then
    die E_VERIFY "内核更新后监听校验失败（旧内核已备份在 ${MH_BIN}.bak-*）"
  fi
  restore_dns
  ok "内核已更新，配置未改动"
}

cmd_uninstall() {
  local purge=0 arg bak=''
  for arg in "$@"; do
    case "$arg" in
      --purge) purge=1 ;;
      *) die E_USAGE "uninstall 不认识的参数：$arg" ;;
    esac
  done

  need_root
  detect_system

  bak="$(backup_now 2>/dev/null || true)"
  if [ -n "$bak" ]; then
    log "已备份配置到 $bak"
  else
    warn "没有可备份的配置目录"
  fi
  svc_remove_units || true
  if have_cmd nft; then
    nft delete table inet mihomo >/dev/null 2>&1 || true
  fi
  # 撤回我们加的 sysctl 落盘（转发开关本身不动，避免影响机器上其它服务）
  if [ -f "$MH_SYSCTL_FILE" ]; then
    rm -f "$MH_SYSCTL_FILE"
    log "已移除 $MH_SYSCTL_FILE（运行时 sysctl 未改动）"
  fi
  rm -f "$MH_BIN"
  rm -f "$MH_CMD"
  rm -rf "$MH_INSTALL_DIR"

  if [ "$purge" = "1" ]; then
    rm -rf "$MH_HOME"
    ok "已卸载并清除 $MH_HOME"
  else
    ok "已卸载内核与服务；配置与凭据保留在 $MH_HOME（加 --purge 才删除）"
  fi
  if [ -n "$bak" ]; then
    log "备份文件：$bak"
  fi
}

cmd_status() {
  local ver='' state='' users=0 fwd=0
  # 先在子 shell 里试跑，避免不支持的发行版把 status 本身弄挂；
  # 确认能识别后再在父 shell 里跑一次，把 MH_INIT 等变量真正落到当前进程。
  if ( detect_system ) >/dev/null 2>&1; then
    detect_system
    log "系统：${MH_OS_ID} ${MH_OS_VER}（${MH_OS_FAMILY}）架构 ${MH_ARCH}，init=${MH_INIT}"
  else
    warn "系统未识别（不影响诊断）"
  fi

  if [ -x "$MH_BIN" ]; then
    ver="$("$MH_BIN" -v 2>/dev/null | sed -n 1p)"
    log "内核：$ver"
  else
    warn "内核未安装：$MH_BIN 不存在"
  fi

  if [ -n "${MH_INIT:-}" ]; then
    state="$(svc_state_text)"
    log "服务状态：$state"
  fi

  if [ -f "$MH_CONFIG" ]; then
    if test_config >/dev/null 2>&1; then
      ok "配置校验：通过（$MH_CONFIG）"
    else
      warn "配置校验：失败（$MH_CONFIG）"
    fi
    log "监听清单："
    expected_listeners | while read -r proto port; do
      [ -n "${port:-}" ] || continue
      if listener_bound "$proto" "$port"; then
        printf '    %s/%s  监听中\n' "$proto" "$port" >&2
      else
        printf '    %s/%s  未监听\n' "$proto" "$port" >&2
      fi
    done
  else
    warn "配置不存在：$MH_CONFIG"
  fi

  if [ -f "$MH_USERS" ]; then
    users="$(jq '.users | length' "$MH_USERS")"
  fi
  if [ -f "$MH_NFT_DB" ]; then
    fwd="$(jq '.forwards | length' "$MH_NFT_DB" 2>/dev/null || echo 0)"
  fi
  log "用户数：$users    端口转发规则数：$fwd"
  if [ -f "$MH_SETTINGS" ] &&
    [ "$(jget '.protocols.vless_reality.enabled // false' "$MH_SETTINGS")" = "true" ]; then
    local rdest_now
    rdest_now="$(jget '.protocols.vless_reality.dest // ""' "$MH_SETTINGS")"
    if reality_dest_ok "$rdest_now"; then
      log "REALITY dest（$rdest_now）：可解析且端口可连通"
    else
      warn "REALITY dest（$rdest_now）：不可解析/不可连通 —— REALITY 会连上即断；修好 DNS 后需重启服务"
    fi
  fi

  if have_cmd nft; then
    if nft list table inet mihomo >/dev/null 2>&1; then
      log "nft 表 inet mihomo：已加载"
    else
      log "nft 表 inet mihomo：未加载"
    fi
  fi

  # DNS 是这类节点最常见的"连得上但全部超时"根因，单独报一行
  if [ -f "$MH_CONFIG" ] && jq -e '.dns.enable == true' "$MH_CONFIG" >/dev/null 2>&1; then
    local ns first
    ns="$(jq -r '.dns.nameserver | join(",")' "$MH_CONFIG")"
    first="$(jq -r '.dns.nameserver[0] // ""' "$MH_CONFIG")"
    if have_cmd dig && [ -n "$first" ]; then
      if dig +short +time=3 +tries=1 "@$first" www.gstatic.com A >/dev/null 2>&1; then
        log "服务端 DNS（mihomo 自带）：$ns —— 首个上游可用"
      else
        warn "服务端 DNS（mihomo 自带）：$ns —— 首个上游 $first 无应答，检查 53/udp 出网"
      fi
    else
      log "服务端 DNS（mihomo 自带）：$ns"
    fi
  elif [ -f "$MH_CONFIG" ]; then
    warn "配置里没有 dns 段：mihomo 会依赖系统 /etc/resolv.conf（DHCP 机器上随时会被改坏）"
  fi
}
