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
# 用资产 API url + Accept: octet-stream（对公开/私有仓库都工作，与程序内自升级 upgrade.rs 一致；
# 私有仓库的 browser_download_url 即使带 token 也 404）。
say "获取最新 Release 信息…"
API="https://api.github.com/repos/$REPO/releases/latest"
AUTH=()
[ -n "${GITHUB_TOKEN:-}" ] && AUTH=(-H "Authorization: Bearer $GITHUB_TOKEN")
JSON=$(curl -fsSL "${AUTH[@]}" -H "Accept: application/vnd.github+json" "$API") || die "获取 Release 失败(网络/仓库不存在?)"
TAG=$(echo "$JSON" | grep -m1 '"tag_name"' | cut -d'"' -f4)
# 每个 asset 的 API url 形如 .../releases/assets/<id>；按 name 定位其 id
asset_api_url() {
  echo "$JSON" | tr ',' '\n' | grep -B3 "\"name\": *\"$1\"" | grep '"url"' | grep '/releases/assets/' | head -1 | cut -d'"' -f4
}
BIN_URL=$(asset_api_url "$ASSET")
SHA_URL=$(asset_api_url "$ASSET.sha256")
[ -n "$TAG" ] && [ -n "$BIN_URL" ] && [ -n "$SHA_URL" ] || die "Release 缺少 $ASSET 附件"
say "最新版本: $TAG"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
curl -fsSL "${AUTH[@]}" -H "Accept: application/octet-stream" -o "$TMP/$ASSET" "$BIN_URL" || die "下载二进制失败"
curl -fsSL "${AUTH[@]}" -H "Accept: application/octet-stream" -o "$TMP/$ASSET.sha256" "$SHA_URL" || die "下载校验文件失败"
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
if [ ! -f "$APP_DIR/.env" ]; then
  # 生成随机管理密码（避免内置可被公开获知的默认密码；用户可在面板改）
  GENPASS=$( (command -v openssl >/dev/null && openssl rand -hex 16) || head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n')
  ( umask 077   # .env 从创建起就 600，杜绝 world-readable 窗口
    cat > "$APP_DIR/.env" <<EOF
# hybot 环境变量(全部参数也可在面板"设置"页配置, 面板配置优先级更高)
USE_TESTNET=false
START_PAUSED=true
DASH_HOST=0.0.0.0
DASH_PORT=8788
DASH_PASS=$GENPASS
# BINANCE_API_KEY=
# BINANCE_API_SECRET=
# CMC_API_KEY=
UPGRADE_REPO=$REPO
EOF
  )
  say "已生成随机管理密码: \033[1;33m$GENPASS\033[0m  （已写入 .env，请妥善保存或在面板改）"
  say "已生成 $APP_DIR/.env (API key 可稍后在面板设置页配置)"
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

if [ "$NO_START" = "1" ]; then
  say "安装完成(未启动)。启动: sudo systemctl start $SERVICE"
else
  $SUDO systemctl start "$SERVICE"
  sleep 2
  systemctl is-active --quiet "$SERVICE" && say "服务已启动 ✓" || die "服务启动失败, 查看: journalctl -u $SERVICE -n 50"
  PORT=$(grep -oP '^DASH_PORT=\K\d+' "$APP_DIR/.env" 2>/dev/null || echo 8788)
  say "面板: http://$(hostname -I | awk '{print $1}'):$PORT  (日志: journalctl -u $SERVICE -f)"
fi
