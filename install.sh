#!/usr/bin/env bash
# hybot 在线安装/更新脚本
# 用法（脚本内部会用 sudo 装 systemd 服务；用 root 运行则不需要 sudo）：
#   # 推荐：先下载再运行，这样 sudo 能在终端弹密码
#   curl -fsSL https://raw.githubusercontent.com/muxang/hybot-release/main/install.sh -o hybot-install.sh && bash hybot-install.sh
#   # 若是 root（或已配置免密 sudo），可直接管道执行：
#   curl -fsSL https://raw.githubusercontent.com/muxang/hybot-release/main/install.sh | bash
#
#   bash install.sh              # 安装/更新到最新 Release
#   bash install.sh --rollback   # 回滚到上一个二进制(hybot.old)
#   bash install.sh --no-start   # 只安装不启动(首次部署想先改 .env 时用)
#
# 说明:
# - 二进制为 musl 静态链接, 免依赖
# - 幂等: 重复执行 = 更新二进制(先停服务, 替换, 再启动)
# - 日志: ①程序自身 logs/bot.log 轮转 5MB×3 ②service 单元限速 ③journald 全局上限(可选 LIMIT_JOURNAL=1)
set -euo pipefail

REPO="muxang/hybot-release"
ASSET="hybot-linux-x86_64"
APP_DIR="${HYBOT_DIR:-$HOME/hybot}"
SERVICE="hybot"
NO_START=0
ROLLBACK=0
for a in "$@"; do
  case "$a" in
    --no-start) NO_START=1 ;;
    --rollback) ROLLBACK=1 ;;
  esac
done

say() { echo -e "\033[1;32m[hybot-install]\033[0m $*"; }
die() { echo -e "\033[1;31m[hybot-install] 错误:\033[0m $*" >&2; exit 1; }

# 获取公网 IP：云 metadata（最可靠）→ 外部回显服务 → 回退内网 IP
pub_ip() {
  local ip=""
  for u in \
    "http://metadata.tencentyun.com/latest/meta-data/public-ipv4" \
    "http://169.254.169.254/latest/meta-data/public-ipv4" \
    "https://api.ipify.org" "https://ifconfig.me" "https://ipinfo.io/ip"; do
    ip=$(curl -s --max-time 4 "$u" 2>/dev/null | tr -d '[:space:]')
    echo "$ip" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' && { echo "$ip"; return; }
  done
  hostname -I 2>/dev/null | awk '{print $1}'
}

# root 直接执行、非 root 用 sudo；都没有则报错指引
if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
elif command -v sudo >/dev/null; then
  SUDO="sudo"
  # 管道执行(curl|bash)时 stdin 是脚本，sudo 无法弹密码 → 先探测免密
  if ! sudo -n true 2>/dev/null && [ ! -t 0 ]; then
    die "需要 sudo 但当前是管道执行且非免密 sudo。请改用：curl -fsSL <url> -o hybot-install.sh && bash hybot-install.sh（或用 root 运行）"
  fi
else
  die "非 root 且无 sudo，无法安装 systemd 服务。请用 root 运行。"
fi

command -v curl >/dev/null || die "需要 curl"
command -v sha256sum >/dev/null || die "需要 sha256sum"
command -v systemctl >/dev/null || die "需要 systemd"
[ "$(uname -m)" = "x86_64" ] || die "仅支持 x86_64 (当前: $(uname -m))"

mkdir -p "$APP_DIR" "$APP_DIR/data" "$APP_DIR/logs"

# ---------- 回滚模式 ----------
if [ "$ROLLBACK" = "1" ]; then
  [ -f "$APP_DIR/hybot.old" ] || die "没有 $APP_DIR/hybot.old 可回滚"
  $SUDO systemctl stop "$SERVICE" || true
  mv "$APP_DIR/hybot" "$APP_DIR/hybot.bad" 2>/dev/null || true
  mv "$APP_DIR/hybot.old" "$APP_DIR/hybot"
  chmod +x "$APP_DIR/hybot"
  $SUDO systemctl start "$SERVICE"
  say "已回滚到上一版本(问题版本保留为 hybot.bad)"
  exit 0
fi

# ---------- 下载最新 Release ----------
say "获取最新 Release 信息…"
API="https://api.github.com/repos/$REPO/releases/latest"
# 所有 curl 都带超时/重试，避免网络卡住时无限挂起
CURL=(curl -fsSL --connect-timeout 20 --max-time 120 --retry 2 --retry-delay 2)
HJSON=(-H "Accept: application/vnd.github+json")
[ -n "${GITHUB_TOKEN:-}" ] && HJSON+=(-H "Authorization: Bearer $GITHUB_TOKEN")
JSON=$("${CURL[@]}" "${HJSON[@]}" "$API") || die "获取 Release 失败(网络不通/仓库不存在/限频?)"

# 解析：优先 python3（健壮，公开/私有仓库都对）；否则回退 grep browser_download_url（公开仓库可用）。
# 公开仓库用 browser_download_url 直下；有 GITHUB_TOKEN(私有仓库)则用资产 API url + octet-stream。
export _ASSET="$ASSET"
if command -v python3 >/dev/null 2>&1; then
  PARSED=$(printf '%s' "$JSON" | python3 -c '
import json,sys,os
d=json.load(sys.stdin); asset=os.environ["_ASSET"]; tok=bool(os.environ.get("GITHUB_TOKEN"))
def find(n):
    for a in d.get("assets",[]):
        if a.get("name")==n: return a
    return None
def url(a): return (a.get("url") if tok else a.get("browser_download_url")) if a else ""
b=find(asset); s=find(asset+".sha256")
print("%s\t%s\t%s\t%s" % (d.get("tag_name",""), url(b), url(s), "api" if tok else "browser"))
' 2>/dev/null) || PARSED=""
  IFS=$'\t' read -r TAG BIN_URL SHA_URL DL_MODE <<<"$PARSED"
else
  TAG=$(printf '%s' "$JSON" | grep -m1 '"tag_name"' | cut -d'"' -f4 || true)
  BIN_URL=$(printf '%s' "$JSON" | grep '"browser_download_url"' | grep "/$ASSET\"" | head -1 | cut -d'"' -f4 || true)
  SHA_URL=$(printf '%s' "$JSON" | grep '"browser_download_url"' | grep "/$ASSET\.sha256\"" | head -1 | cut -d'"' -f4 || true)
  DL_MODE=browser
fi
[ -n "${TAG:-}" ] && [ -n "${BIN_URL:-}" ] && [ -n "${SHA_URL:-}" ] || \
  die "解析 Release 附件失败(TAG='${TAG:-}')。请确认 $REPO 有 $ASSET 附件。JSON 前 200 字符：$(printf '%s' "$JSON" | head -c 200)"
say "最新版本: $TAG（下载方式: $DL_MODE）"

# 下载：browser 模式直下（公开仓库无需鉴权）；api 模式带 octet-stream(+token)
DLH=()
[ "$DL_MODE" = "api" ] && DLH+=(-H "Accept: application/octet-stream")
[ "$DL_MODE" = "api" ] && [ -n "${GITHUB_TOKEN:-}" ] && DLH+=(-H "Authorization: Bearer $GITHUB_TOKEN")
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
say "下载二进制…"
"${CURL[@]}" "${DLH[@]}" -o "$TMP/$ASSET" "$BIN_URL" || die "下载二进制失败"
"${CURL[@]}" "${DLH[@]}" -o "$TMP/$ASSET.sha256" "$SHA_URL" || die "下载校验文件失败"
say "校验 sha256…"
(cd "$TMP" && sha256sum -c "$ASSET.sha256" >/dev/null) || die "sha256 校验失败, 中止"

# ---------- 安装二进制(保留旧版为 .old 供回滚) ----------
if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
  say "停止运行中的服务…"
  $SUDO systemctl stop "$SERVICE"
fi
[ -f "$APP_DIR/hybot" ] && cp -f "$APP_DIR/hybot" "$APP_DIR/hybot.old"
install -m 755 "$TMP/$ASSET" "$APP_DIR/hybot"
say "二进制已安装: $APP_DIR/hybot ($TAG)"

# ---------- .env(仅首次生成, 不覆盖已有配置) ----------
gen_pass() { (command -v openssl >/dev/null && openssl rand -hex 16) || head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
if [ ! -f "$APP_DIR/.env" ]; then
  ( umask 077   # .env 从创建起就 600，杜绝 world-readable 窗口
    cat > "$APP_DIR/.env" <<EOF
# hybot 环境变量(全部参数也可在面板"设置"页配置, 面板配置优先级更高)
USE_TESTNET=false
START_PAUSED=true
DASH_HOST=0.0.0.0
DASH_PORT=8788
DASH_PASS=
# BINANCE_API_KEY=
# BINANCE_API_SECRET=
# CMC_API_KEY=
UPGRADE_REPO=$REPO
EOF
  )
  say "已生成 $APP_DIR/.env (API key 可稍后在面板设置页配置)"
fi

# 确保有管理密码：旧 .env 可能没设/是占位符/为空 —— 都补一个随机密码（不覆盖已有的真密码）
CURPASS=$(grep -m1 '^DASH_PASS=' "$APP_DIR/.env" 2>/dev/null | cut -d= -f2- | tr -d '\r')
if [ -z "$CURPASS" ] || [ "$CURPASS" = "请改成你的管理密码" ]; then
  CURPASS=$(gen_pass)
  if grep -q '^DASH_PASS=' "$APP_DIR/.env"; then
    sed -i "s#^DASH_PASS=.*#DASH_PASS=$CURPASS#" "$APP_DIR/.env"
  else
    echo "DASH_PASS=$CURPASS" >> "$APP_DIR/.env"
  fi
  chmod 600 "$APP_DIR/.env"
fi

# ---------- systemd 服务 ----------
$SUDO tee /etc/systemd/system/$SERVICE.service >/dev/null <<EOF
[Unit]
Description=hybot binance futures bot
After=network-online.target
Wants=network-online.target

[Service]
User=$USER
WorkingDirectory=$APP_DIR
ExecStart=$APP_DIR/hybot
Restart=always
RestartSec=3
# 升级流程 = 自替换二进制后 exit 0, 由 Restart=always 拉起新版
LimitNOFILE=65536
# 日志限速: 30s 内超过 2000 条丢弃(防异常刷屏撑爆 journal)
LogRateLimitIntervalSec=30
LogRateLimitBurst=2000

[Install]
WantedBy=multi-user.target
EOF

# ---------- 日志大小控制 ----------
# 三层：① 程序自身 logs/bot.log 轮转 5MB×3（默认，已隔离到本服务）
#      ② service 单元 LogRateLimit 限速（上面 unit 里，仅本服务）
#      ③ journald 全局上限（可选，默认不动——它影响 VPS 上所有服务的日志保留量）
# 想启用全局 journald 上限：LIMIT_JOURNAL=1 bash install.sh
if [ "${LIMIT_JOURNAL:-0}" = "1" ] && [ ! -f /etc/systemd/journald.conf.d/99-hybot.conf ]; then
  $SUDO mkdir -p /etc/systemd/journald.conf.d
  $SUDO tee /etc/systemd/journald.conf.d/99-hybot.conf >/dev/null <<EOF
[Journal]
SystemMaxUse=200M
RuntimeMaxUse=100M
EOF
  $SUDO systemctl restart systemd-journald || true
  say "journald 全局日志上限已设为 200M（影响所有服务）"
else
  say "journald 全局上限未改（程序自身 logs/bot.log 已轮转；如需全局限制用 LIMIT_JOURNAL=1）"
fi

$SUDO systemctl daemon-reload
$SUDO systemctl enable "$SERVICE" >/dev/null

PORT=$(grep -oP '^DASH_PORT=\K\d+' "$APP_DIR/.env" 2>/dev/null || echo 8788)
if [ "$NO_START" = "1" ]; then
  say "安装完成(未启动)。启动: sudo systemctl start $SERVICE"
else
  $SUDO systemctl start "$SERVICE"
  sleep 2
  systemctl is-active --quiet "$SERVICE" || die "服务启动失败, 查看: journalctl -u $SERVICE -n 50"
  say "服务已启动 ✓"
fi

# ---------- 安装完成信息（始终显示：公网 IP + 面板地址 + 管理密码）----------
IP=$(pub_ip)
echo
echo -e "\033[1;36m========== hybot 安装完成 ($TAG) ==========\033[0m"
echo -e "  面板地址:  \033[1;32mhttp://$IP:$PORT\033[0m"
echo -e "  管理密码:  \033[1;33m$CURPASS\033[0m   （写操作/登录用，可在面板设置页改）"
echo -e "  日志查看:  journalctl -u $SERVICE -f   或   tail -f $APP_DIR/logs/bot.log"
echo -e "  \033[1;31m提示\033[0m: 若面板打不开，请到云服务器安全组放行 TCP 端口 \033[1;33m$PORT\033[0m（公网入站）"
echo -e "        进面板后到「设置」配置 币安 Key/Secret + CoinMarketCap Key，保存后自动连接"
echo -e "\033[1;36m===========================================\033[0m"
