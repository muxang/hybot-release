#!/usr/bin/env bash
# hybot 在线安装/更新脚本
# 用法:
#   curl -fsSL https://raw.githubusercontent.com/muxang/hybot-release/main/install.sh | bash
#   bash install.sh              # 安装/更新到最新 Release
#   bash install.sh --rollback   # 回滚到上一个二进制(hybot.old)
#   bash install.sh --no-start   # 只安装不启动(首次部署想先改 .env 时用)
#
# 说明:
# - 二进制为 musl 静态链接, 免依赖
# - 幂等: 重复执行 = 更新二进制(先停服务, 替换, 再启动)
# - 日志三层控制:
#     1) 程序自身: logs/bot.log 轮转 5MB×3
#     2) journald: 全局上限 SystemMaxUse=200M (drop-in)
#     3) service 单元: 日志限速防刷屏
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

command -v curl >/dev/null || die "需要 curl"
command -v sha256sum >/dev/null || die "需要 sha256sum"
command -v systemctl >/dev/null || die "需要 systemd"
[ "$(uname -m)" = "x86_64" ] || die "仅支持 x86_64 (当前: $(uname -m))"

mkdir -p "$APP_DIR" "$APP_DIR/data" "$APP_DIR/logs"

# ---------- 回滚模式 ----------
if [ "$ROLLBACK" = "1" ]; then
  [ -f "$APP_DIR/hybot.old" ] || die "没有 $APP_DIR/hybot.old 可回滚"
  sudo systemctl stop "$SERVICE" || true
  mv "$APP_DIR/hybot" "$APP_DIR/hybot.bad" 2>/dev/null || true
  mv "$APP_DIR/hybot.old" "$APP_DIR/hybot"
  chmod +x "$APP_DIR/hybot"
  sudo systemctl start "$SERVICE"
  say "已回滚到上一版本(问题版本保留为 hybot.bad)"
  exit 0
fi

# ---------- 下载最新 Release ----------
say "获取最新 Release 信息…"
API="https://api.github.com/repos/$REPO/releases/latest"
AUTH=()
[ -n "${GITHUB_TOKEN:-}" ] && AUTH=(-H "Authorization: Bearer $GITHUB_TOKEN")
JSON=$(curl -fsSL "${AUTH[@]}" "$API") || die "获取 Release 失败(网络/仓库不存在?)"
TAG=$(echo "$JSON" | grep -m1 '"tag_name"' | cut -d'"' -f4)
BIN_URL=$(echo "$JSON" | grep '"browser_download_url"' | grep "$ASSET\"" | cut -d'"' -f4)
SHA_URL=$(echo "$JSON" | grep '"browser_download_url"' | grep "$ASSET.sha256" | cut -d'"' -f4)
[ -n "$TAG" ] && [ -n "$BIN_URL" ] && [ -n "$SHA_URL" ] || die "Release 缺少 $ASSET 附件"
say "最新版本: $TAG"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
curl -fsSL "${AUTH[@]}" -o "$TMP/$ASSET" "$BIN_URL" || die "下载二进制失败"
curl -fsSL "${AUTH[@]}" -o "$TMP/$ASSET.sha256" "$SHA_URL" || die "下载校验文件失败"
say "校验 sha256…"
(cd "$TMP" && sha256sum -c "$ASSET.sha256" >/dev/null) || die "sha256 校验失败, 中止"

# ---------- 安装二进制(保留旧版为 .old 供回滚) ----------
if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
  say "停止运行中的服务…"
  sudo systemctl stop "$SERVICE"
fi
[ -f "$APP_DIR/hybot" ] && cp -f "$APP_DIR/hybot" "$APP_DIR/hybot.old"
install -m 755 "$TMP/$ASSET" "$APP_DIR/hybot"
say "二进制已安装: $APP_DIR/hybot ($TAG)"

# ---------- .env(仅首次生成, 不覆盖已有配置) ----------
if [ ! -f "$APP_DIR/.env" ]; then
  cat > "$APP_DIR/.env" <<EOF
# hybot 环境变量(全部参数也可在面板"设置"页配置, 面板配置优先级更高)
USE_TESTNET=false
START_PAUSED=true
DASH_HOST=0.0.0.0
DASH_PORT=8788
DASH_PASS=请改成你的管理密码
# BINANCE_API_KEY=
# BINANCE_API_SECRET=
# CMC_API_KEY=
UPGRADE_REPO=$REPO
EOF
  chmod 600 "$APP_DIR/.env"
  say "已生成 $APP_DIR/.env (请填写密码/密钥, 或稍后在面板设置页配置)"
fi

# ---------- systemd 服务 ----------
sudo tee /etc/systemd/system/$SERVICE.service >/dev/null <<EOF
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

# ---------- journald 大小上限(全局 200M, 影响所有服务的持久日志) ----------
if [ ! -f /etc/systemd/journald.conf.d/99-hybot.conf ]; then
  sudo mkdir -p /etc/systemd/journald.conf.d
  sudo tee /etc/systemd/journald.conf.d/99-hybot.conf >/dev/null <<EOF
[Journal]
SystemMaxUse=200M
RuntimeMaxUse=100M
EOF
  sudo systemctl restart systemd-journald || true
  say "journald 日志上限已设为 200M"
fi

sudo systemctl daemon-reload
sudo systemctl enable "$SERVICE" >/dev/null

if [ "$NO_START" = "1" ]; then
  say "安装完成(未启动)。启动: sudo systemctl start $SERVICE"
else
  sudo systemctl start "$SERVICE"
  sleep 2
  systemctl is-active --quiet "$SERVICE" && say "服务已启动 ✓" || die "服务启动失败, 查看: journalctl -u $SERVICE -n 50"
  PORT=$(grep -oP '^DASH_PORT=\K\d+' "$APP_DIR/.env" 2>/dev/null || echo 8788)
  say "面板: http://$(hostname -I | awk '{print $1}'):$PORT  (日志: journalctl -u $SERVICE -f)"
fi
