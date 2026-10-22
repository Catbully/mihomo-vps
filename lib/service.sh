#!/usr/bin/env bash
# shellcheck shell=bash
# 服务层：systemd（Debian/Ubuntu）与 OpenRC（Alpine）两套实现，对外接口一致。

MH_SVC=mihomo
MH_SVC_NFT=mihomo-nft

# ---------- 单元/脚本安装 ----------
svc_install_units() {
  case "$MH_INIT" in
    systemd) svc_install_systemd ;;
    openrc) svc_install_openrc ;;
    *) die E_UNSUPPORTED_INIT "未知 init 系统：$MH_INIT" ;;
  esac
}

svc_install_systemd() {
  cat >"/etc/systemd/system/${MH_SVC}.service" <<EOF
[Unit]
Description=mihomo server (inbound listeners)
Documentation=https://wiki.metacubex.one
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${MH_BIN} -d ${MH_HOME}
Restart=on-failure
RestartSec=3s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

svc_install_openrc() {
  cat >"/etc/init.d/${MH_SVC}" <<EOF
#!/sbin/openrc-run
name="mihomo"
description="mihomo server (inbound listeners)"
command="${MH_BIN}"
command_args="-d ${MH_HOME}"
command_background=true
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="${MH_LOG_FILE}"
error_log="${MH_LOG_FILE}"

depend() {
	need net
	after firewall
}
EOF
  chmod 0755 "/etc/init.d/${MH_SVC}"
}

# 端口转发规则的服务单元（自带，绝不接管系统的 nftables.service）
svc_nft_install_units() {
  local nft_bin
  nft_bin="$(command -v nft || echo /usr/sbin/nft)"
  case "$MH_INIT" in
    systemd)
      cat >"/etc/systemd/system/${MH_SVC_NFT}.service" <<EOF
[Unit]
Description=mihomo nftables port forwarding rules
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${nft_bin} -f ${MH_NFT_FILE}
ExecReload=${nft_bin} -f ${MH_NFT_FILE}

[Install]
WantedBy=multi-user.target
EOF
      systemctl daemon-reload
      ;;
    openrc)
      cat >"/etc/init.d/${MH_SVC_NFT}" <<EOF
#!/sbin/openrc-run
name="mihomo-nft"
description="mihomo nftables port forwarding rules"

start() {
	ebegin "Loading mihomo nft rules"
	${nft_bin} -f ${MH_NFT_FILE}
	eend \$?
}

stop() {
	ebegin "Removing mihomo nft table"
	${nft_bin} delete table inet mihomo 2>/dev/null
	eend 0
}
EOF
      chmod 0755 "/etc/init.d/${MH_SVC_NFT}"
      ;;
    *) die E_UNSUPPORTED_INIT "未知 init 系统：$MH_INIT" ;;
  esac
}

svc_remove_units() {
  case "$MH_INIT" in
    systemd)
      systemctl disable --now "$MH_SVC" >/dev/null 2>&1 || true
      systemctl disable --now "$MH_SVC_NFT" >/dev/null 2>&1 || true
      rm -f "/etc/systemd/system/${MH_SVC}.service" "/etc/systemd/system/${MH_SVC_NFT}.service"
      systemctl daemon-reload || true
      ;;
    openrc)
      rc-service "$MH_SVC" stop >/dev/null 2>&1 || true
      rc-service "$MH_SVC_NFT" stop >/dev/null 2>&1 || true
      rc-update del "$MH_SVC" default >/dev/null 2>&1 || true
      rc-update del "$MH_SVC_NFT" default >/dev/null 2>&1 || true
      rm -f "/etc/init.d/${MH_SVC}" "/etc/init.d/${MH_SVC_NFT}"
      ;;
  esac
}

# ---------- 生命周期 ----------
svc_start() {
  case "$MH_INIT" in
    systemd) systemctl start "$MH_SVC" ;;
    openrc) rc-service "$MH_SVC" start ;;
  esac
}

svc_stop() {
  case "$MH_INIT" in
    systemd) systemctl stop "$MH_SVC" ;;
    openrc) rc-service "$MH_SVC" stop ;;
  esac
}

svc_restart() {
  case "$MH_INIT" in
    systemd) systemctl restart "$MH_SVC" ;;
    openrc) rc-service "$MH_SVC" restart ;;
  esac
}

svc_enable() {
  case "$MH_INIT" in
    systemd) systemctl enable "$MH_SVC" >/dev/null ;;
    openrc) rc-update add "$MH_SVC" default >/dev/null ;;
  esac
}

svc_nft_enable() {
  case "$MH_INIT" in
    systemd) systemctl enable "$MH_SVC_NFT" >/dev/null ;;
    openrc) rc-update add "$MH_SVC_NFT" default >/dev/null ;;
  esac
}

svc_nft_reload() {
  case "$MH_INIT" in
    systemd) systemctl restart "$MH_SVC_NFT" ;;
    openrc) rc-service "$MH_SVC_NFT" restart 2>/dev/null || rc-service "$MH_SVC_NFT" start ;;
  esac
}

svc_is_active() {
  case "$MH_INIT" in
    systemd) systemctl is-active --quiet "$MH_SVC" ;;
    openrc) rc-service "$MH_SVC" status >/dev/null 2>&1 ;;
  esac
}

svc_state_text() {
  case "$MH_INIT" in
    systemd) systemctl is-active "$MH_SVC" 2>/dev/null || true ;;
    openrc)
      if svc_is_active; then echo started; else echo stopped; fi
      ;;
  esac
}

# 最近日志：systemd 走 journald，OpenRC 走日志文件
svc_recent_log() {
  local since="${1:-3 min ago}"
  case "$MH_INIT" in
    systemd) journalctl -u "$MH_SVC" --since "-${since}" --no-pager 2>/dev/null || true ;;
    openrc)
      if [ -r "$MH_LOG_FILE" ]; then
        tail -n 120 "$MH_LOG_FILE"
      fi
      ;;
  esac
}
