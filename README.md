# mihomo-vps

给一台 VPS 安装并**运维** [mihomo](https://github.com/MetaCubeX/mihomo) **服务端**（入站代理）的交互式 Bash 脚本，附带 nftables 端口转发与客户端凭据发放。

> 只做「入站代理 + nftables 端口转发」。**不做** TUN 网关、**不做** mihomo 层的出站链式中转、**不做**订阅服务端、不接管系统的 nftables/防火墙服务。

## 支持的系统

| 发行版 | 版本 | init | 架构 |
|---|---|---|---|
| Debian | 12 / 13 | systemd | amd64 / arm64 |
| Ubuntu | 22.04 / 24.04 | systemd | amd64 / arm64 |
| Alpine | 3.19+ | OpenRC | amd64 / arm64 |

其它系统会被明确拒绝（`E_UNSUPPORTED_OS`），不做「看起来能装」的半支持。

## 快速开始

```bash
# ① 一键装（最稳，推荐）：先落盘再跑，root 与非 root 都成立
curl -fsSLo /tmp/mihomo.sh https://raw.githubusercontent.com/Catbully/mihomo-vps/main/mihomo.sh
sudo bash /tmp/mihomo.sh

# ② 已经是 root：直接跑，不用 sudo
bash <(curl -fsSL https://raw.githubusercontent.com/Catbully/mihomo-vps/main/mihomo.sh)

# ③ 非 root 又想一条命令：把 <(...) 放进 bash -c 内部，让进程替换发生在 sudo 里面
sudo bash -c 'bash <(curl -fsSL https://raw.githubusercontent.com/Catbully/mihomo-vps/main/mihomo.sh)'

# ④ 非交互：lite 预设（SS-2022 + Hysteria2），其余全默认
sudo bash /tmp/mihomo.sh install --yes

# ⑤ 机器 DNS 坏了、连脚本都拉不下来（curl: (6)）：先修 DNS 再下
sudo bash -c '
  cp -a /etc/resolv.conf /root/resolv.conf.bak 2>/dev/null || true
  printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\n" > /etc/resolv.conf
  bash <(curl -fsSL https://raw.githubusercontent.com/Catbully/mihomo-vps/main/mihomo.sh)
'

# ⑥ 先克隆再跑（方便改代码）
git clone https://github.com/Catbully/mihomo-vps && cd mihomo-vps
bash mihomo.sh            # 或 ./mihomo.sh（需先 chmod +x mihomo.sh）
```

### 排错

| 现象 | 真正原因 | 怎么办 |
|---|---|---|
| `curl: (6) Could not resolve host` | 本机 DNS 不通 | 用上表 ⑤ 先修 DNS 再跑 |
| `bash: /dev/fd/63: No such file or directory`（常伴随 `curl: (23) Failure writing output to destination`） | **`sudo bash <(curl ...)` 不成立**：`sudo` 默认关闭多余文件描述符，`<(...)` 那条管道是父 shell 建的，进 sudo 子进程后已不存在 | 用 ①（落盘再跑）或 ③（`sudo bash -c '...'`），别写 `sudo bash <(...)` |
| `sudo: unable to resolve host <主机名>` | 主机名不在 `/etc/hosts`，纯提示，不影响功能 | 已是 root 就别用 sudo；或 `echo "127.0.1.1 $(hostname)" >> /etc/hosts` |
| 想非交互却进了菜单 | `bash <(curl ...)` 不带子命令就是交互菜单，重定向喂的答案会被菜单吃掉 | 写子命令，例如 `... install --yes` |
| `[E] E_BOOTSTRAP: 下载仓库失败` | 自举下载不到 tar.gz（DNS/网络/镜像） | 按提示先修 DNS，或设 `MIHOMO_MIRROR=<镜像前缀>` |

自举说明：单文件运行时脚本身边没有 `lib/`，脚本会自动下载仓库压缩包到临时目录、前台重新执行（**前台执行**保证交互菜单仍能读终端 stdin），结束后清理临时目录。镜像用 `MIHOMO_MIRROR=<前缀>`，fork 用 `MH_REPO_SLUG=<owner/repo>`。

> **刻意不用 `curl ... | bash`**：管道会把 stdin 占掉，交互菜单就读不到你的输入了。
## 装完之后的常驻命令

`install` 会把脚本自身落地到 `/usr/local/lib/mihomo-vps/`，并生成命令 **`mihomo-vps`**：

```bash
mihomo-vps            # 打开管理菜单
mihomo-vps status     # 任何子命令都等价于 ./mihomo.sh <子命令>
```

> ⚠️ **为什么命令不叫 `mihomo`**：`/usr/local/bin/mihomo` 是 mihomo 内核本体（systemd 单元启的就是它），同名会把内核顶掉。所以管理命令固定为 `mihomo-vps`。

`install`、`user add`、`clients` 生成节点后都会**直接把分享链接与 proxies 片段打印到终端**（正文走 stdout，可重定向保存；标题走 stderr）；不想要输出就加 `--no-print`。


## 命令

```bash
./mihomo.sh                        # 交互菜单
./mihomo.sh install [--yes] [--fix-dns]
./mihomo.sh reconfig               # 同 install：修改协议/端口/证书
./mihomo.sh user add <名字> [--ss]  # 加用户；--ss 额外分配独占 SS 端口
./mihomo.sh user remove <名字>
./mihomo.sh user list|show <名字>|export
./mihomo.sh user enable|disable <名字>
./mihomo.sh forward add --listen-port 24080 --proto tcp --to 1.2.3.4:8080 [--no-masquerade]
./mihomo.sh forward add --listen-port 24081 --proto tcp --redirect-to 7891
./mihomo.sh forward del|list|flush|apply
./mihomo.sh self-install           # 只落地脚本并生成 mihomo-vps 命令（install 会自动做）
./mihomo.sh clients --all [--full] [--qr] [--no-print]  # 打印所有用户的链接 + proxies
./mihomo.sh clients --user <名字> [--full] [--qr]
./mihomo.sh update [tag]           # 换内核，保留配置
./mihomo.sh status                 # 状态与诊断
./mihomo.sh uninstall [--purge]
```

## 协议矩阵

安装时勾选，预设 `lite = 1,6`、`full = 1,2,3,4,5,6,7`。

| # | 协议 | 入站 type | 传输/安全 | 多用户 | 端口语义 |
|---|---|---|---|---|---|
| 1 | Shadowsocks-2022 | `shadowsocks` | `2022-blake3-aes-128-gcm` | **否**（单 `password`） | TCP+UDP，**每用户独占端口** |
| 2 | VLESS + Vision + TLS | `vless` | `flow: xtls-rprx-vision` + 证书 | 是（`users[]`） | TCP |
| 3 | VLESS + REALITY | `vless` | `reality-config`（与证书互斥） | 是（`users[]`） | TCP |
| 4 | Trojan + TLS | `trojan` | 证书 | 是（`users[]`） | TCP |
| 5 | VMess + WS + TLS | `vmess` | `ws-path`（仅 path，无自定义 header） | 是（`users[]`） | TCP |
| 6 | Hysteria2 | `hysteria2` | 证书 + 可选 `obfs: salamander` | 是（`users` 映射） | **UDP/QUIC** |
| 7 | Tuic | `tuic` | 证书，`users` = UUID→密码 | 是（`users` 映射） | **UDP/QUIC** |

用户是**跨协议的一套身份**：`user add alice` 会在所有已启用协议上为 alice 生成凭据。唯一例外是 Shadowsocks —— mihomo 的 ss 入站只有单个 `password`，所以 `--ss` 才会给该用户单独开一个 listener/端口。

## 文件布局

```
/usr/local/bin/mihomo                     # 内核（旧版备份为 mihomo.bak-<时间戳>）
/etc/mihomo/
├── settings.json                         # 协议、端口、证书、REALITY 参数
├── users.json                            # 唯一数据源：用户凭据
├── config.yaml                           # 渲染产物（JSON 内容，mihomo 可直接解析）
├── certs/{fullchain.pem,privkey.pem}     # 必须在 home 目录内，否则 listener 静默失败
├── nft/forward.nft                       # table inet mihomo
├── nft/forwards.json                     # 转发规则数据源
└── clients/<用户>/{proxies.yaml,links.txt[,client.yaml]}
/var/backups/mihomo-<时间戳>.tar.gz
```

服务单元：systemd `mihomo.service` + `mihomo-nft.service`；Alpine `/etc/init.d/mihomo` + `/etc/init.d/mihomo-nft`。

## 为什么每次变更都要「真启动」验证

`mihomo -t` 是**浅校验**：不读证书文件、不校验 REALITY/SS 密钥格式、不检查 reality 与 certificate 互斥、也不绑定端口。实测这些错误全部只在运行时爆出来：

- `disallow using Vless without any certificates/shadow-tls/res-tls/jls/reality/...`
- `security modes are mutually exclusive: certificate, reality`
- `Listener ... listen err: invalid private key`
- `parse certificate failed ... path is not subpath of home directory or SAFE_PATHS`

因此 `apply_config` 的流水线是：**渲染 → `mihomo -t` → 重启 → 逐端口 `ss` 校验（TCP/UDP 分别）→ 日志扫描 → 任一失败自动回滚**。

## 端口转发（nftables）

- `dnat`：本机端口 → 远端 `host:port`（IPv4/IPv6 字面量自动选 family）
- `redirect`：本机端口 → 本机另一个端口
- `masquerade`：默认开启（让回程也经本机），`--no-masquerade` 关闭

规则写在独立表 `table inet mihomo`，由自带的 `mihomo-nft.service` 开机加载。**不会**启用系统的 `nftables.service`，也**不会**改写 `/etc/nftables.conf`。

DNAT 需要内核转发能力，脚本会自动写 `/etc/sysctl.d/99-mihomo-forward.conf` 并开启 `net.ipv4.ip_forward`（目标为 IPv6 时同时开 `net.ipv6.conf.all.forwarding`），卸载时移除该 drop-in 但**不改运行时的 sysctl**。实测教训：`ip_forward=0` 时端口能连上、规则看着正常，但数据永远回不来。

## 安全与越权边界

- 需要 root；所有状态文件 600，`/etc/mihomo` 与 `certs/` 700。
- 默认自签证书（生成一次、固定复用）。**不留空**：hysteria2/tuic 在证书为空时会自动生成随机自签，重启即换证书，客户端会全部失效。
- 支持导入已有证书，但会**复制**进 `/etc/mihomo/certs/`（mihomo 不允许 home 之外的证书路径）。
- 网络不可用时默认**拒绝安装**并打印修复命令；只有显式 `--fix-dns` 才临时写 `nameserver 1.1.1.1`（先备份 `/etc/resolv.conf`，退出时还原）。
- `uninstall` 默认保留 `/etc/mihomo`（凭据在里面），`--purge` 才删除；卸载与重配前都强制备份。
- 镜像：设 `MIHOMO_MIRROR=https://ghfast.top/` 之类的**前缀**即可走镜像，失败会自动回退直连 GitHub。

## 错误码

| 错误码 | 含义 |
|---|---|
| `E_NOT_ROOT` | 未用 root 运行 |
| `E_UNSUPPORTED_OS` / `E_UNSUPPORTED_ARCH` / `E_UNSUPPORTED_INIT` | 系统/架构/init 不受支持 |
| `E_MISSING_CMD` / `E_PKG` | 依赖缺失或安装失败 |
| `E_DNS_BROKEN` | 网络/DNS 不可用 |
| `E_DOWNLOAD` / `E_BINARY` | 内核下载或执行失败 |
| `E_CERT` / `E_REALITY` | 证书或 REALITY 参数问题 |
| `E_RENDER` / `E_CONFIG_INVALID` / `E_VERIFY` | 渲染、`-t` 校验、运行期监听校验失败（后两者已回滚） |
| `E_PORT_IN_USE` / `E_PORT_DUP` / `E_NO_FREE_PORT` | 端口冲突 |
| `E_FWD_DUP` / `E_FWD_NOTFOUND` / `E_NFT` | 转发规则问题 |
| `E_USER` | 用户操作问题 |

## 开发与校验

```bash
bash -n mihomo.sh lib/*.sh
shellcheck --severity=warning --shell=bash --external-sources mihomo.sh lib/*.sh
```

## 已知限制

- **Alpine 未在实机验证**（本项目测试机是 Debian 12）。OpenRC 脚本与 busybox 差异只经过静态检查。
- `-t` 的浅校验意味着仍有「端口绑上了但协议不通」的极小可能，脚本用本机客户端自连补最后一层。
- REALITY 的 `dest` 是第三方站点，长期可用性不由本脚本控制（默认 `itunes.apple.com:443`，已核实支持 TLS 1.3 + h2）。**REALITY 依赖服务端能解析并连通 dest**：dest 不通时现象是「连上即断」，`mihomo -t` 和端口校验都发现不了；`status` 会单独探测并告警，修好 DNS 后需 `systemctl restart mihomo` 才生效。
- VMess WS 只有 `ws-path`，客户端若自定义 Host 头会不匹配。
- SS-2022 的密钥长度随 cipher 变化（16B/32B），脚本按 cipher 生成对应长度。
