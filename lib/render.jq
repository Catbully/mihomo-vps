# mihomo 服务端配置渲染器（jq）
#
# 输入：settings.json（作为主输入 .）
# 参数：--slurpfile users users.json
# 输出：JSON 文本（JSON 是 YAML 1.2 子集，mihomo 的 YAML 解析器可直接读取）
#
# 实测约束（v1.19.33）：
#   * ss 入站只有单个 password，没有 users 数组 → 每个用户一个独立 listener/端口。
#   * trojan/vless/vmess 的 users 是列表；hysteria2/tuic 的 users 是映射。
#   * reality-config 的 short-id 必须是列表；reality 与 certificate 互斥。
#   * vless/trojan 必须有证书、reality、或 allow-insecure，否则运行时拒绝启动。
#   * 证书路径必须是 mihomo home 目录下的子路径。

def tls_block($s): {
  certificate: $s.tls.cert,
  "private-key": $s.tls.key
};

def ss_block($s; $u):
  if ($s.protocols.ss.enabled | not) then []
  else
    [ $u[] | select(.ss != null) | {
        name: ("ss-" + .name),
        type: "shadowsocks",
        listen: $s.listen,
        port: .ss.port,
        cipher: $s.protocols.ss.cipher,
        password: .ss.password
      } ]
  end;

def vless_tls_block($s; $u):
  if ($s.protocols.vless_tls.enabled | not) then []
  else
    [ ({
        name: "vless-tls",
        type: "vless",
        listen: $s.listen,
        port: $s.protocols.vless_tls.port,
        users: [ $u[] | { username: .name, uuid: .uuid, flow: "xtls-rprx-vision" } ]
      } + tls_block($s)) ]
  end;

def vless_reality_block($s; $u):
  if ($s.protocols.vless_reality.enabled | not) then []
  else
    [ {
        name: "vless-reality",
        type: "vless",
        listen: $s.listen,
        port: $s.protocols.vless_reality.port,
        users: [ $u[] | { username: .name, uuid: .uuid, flow: "xtls-rprx-vision" } ],
        "reality-config": {
          dest: $s.protocols.vless_reality.dest,
          "private-key": $s.protocols.vless_reality.private_key,
          "short-id": $s.protocols.vless_reality.short_id,
          "server-names": $s.protocols.vless_reality.server_names
        }
      } ]
  end;

def trojan_block($s; $u):
  if ($s.protocols.trojan.enabled | not) then []
  else
    [ ({
        name: "trojan",
        type: "trojan",
        listen: $s.listen,
        port: $s.protocols.trojan.port,
        users: [ $u[] | { username: .name, password: .password } ]
      } + tls_block($s)) ]
  end;

def vmess_block($s; $u):
  if ($s.protocols.vmess.enabled | not) then []
  else
    [ ({
        name: "vmess",
        type: "vmess",
        listen: $s.listen,
        port: $s.protocols.vmess.port,
        "ws-path": $s.protocols.vmess.ws_path,
        users: [ $u[] | { username: .name, uuid: .uuid } ]
      } + tls_block($s)) ]
  end;

def hysteria2_block($s; $u):
  if ($s.protocols.hysteria2.enabled | not) then []
  else
    [ ({
        name: "hysteria2",
        type: "hysteria2",
        listen: $s.listen,
        port: $s.protocols.hysteria2.port,
        users: ($u | map({ (.name): .password }) | add // {}),
        obfs: $s.protocols.hysteria2.obfs,
        "obfs-password": $s.protocols.hysteria2.obfs_password,
        "ignore-client-bandwidth": true
      } + tls_block($s)) ]
  end;

def tuic_block($s; $u):
  if ($s.protocols.tuic.enabled | not) then []
  else
    [ ({
        name: "tuic",
        type: "tuic",
        listen: $s.listen,
        port: $s.protocols.tuic.port,
        users: ($u | map({ (.uuid): .password }) | add // {}),
        alpn: [ "h3" ],
        "congestion-controller": "bbr"
      } + tls_block($s)) ]
  end;

. as $s
| ([ $users[0].users[] | select(.enabled != false) ]) as $u
| { "log-level": ($s.log_level // "info") }
+ {
    # 服务端必须能自己解析被代理的域名。若只依赖系统解析器，任何一台 DHCP 机器
    # （dhclient/systemd-networkd 续租会重写 /etc/resolv.conf）或 DNS 坏掉的机器，
    # 都会表现为"客户端连得上但所有网站超时"。
    dns: {
      enable: true,
      "enhanced-mode": "normal",
      "use-hosts": true,
      ipv6: false,
      "default-nameserver": ($s.dns.default_nameserver // [ "1.1.1.1", "223.5.5.5" ]),
      nameserver: ($s.dns.nameserver // [ "1.1.1.1", "223.5.5.5", "9.9.9.9" ]),
      fallback: ($s.dns.fallback // [])
    }
  }
+ {
    listeners: (
      ss_block($s; $u)
      + vless_tls_block($s; $u)
      + vless_reality_block($s; $u)
      + trojan_block($s; $u)
      + vmess_block($s; $u)
      + hysteria2_block($s; $u)
      + tuic_block($s; $u)
    )
  }
| walk(
    if type == "object" then
      with_entries(select(.value != null and .value != "" and .value != []))
    else . end
  )
