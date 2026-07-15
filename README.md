# hybot-release

hybot（币安 U 本位合约 bot）的**升级产物仓库**：仅存放编译好的二进制、sha256 校验文件与安装脚本。
无源码、无任何密钥/配置。

## 安装 / 更新到最新版

脚本内部用 sudo 安装 systemd 服务，推荐先下载再运行（这样 sudo 能在终端弹密码）：

```bash
curl -fsSL https://raw.githubusercontent.com/muxang/hybot-release/main/install.sh -o hybot-install.sh && bash hybot-install.sh
```

若用 root（或已配置免密 sudo），也可直接管道执行：

```bash
curl -fsSL https://raw.githubusercontent.com/muxang/hybot-release/main/install.sh | bash
```

首次安装会生成随机管理密码并打印出来（也写入 `~/hybot/.env` 的 `DASH_PASS`）。

## 回滚上一版本

```bash
curl -fsSL https://raw.githubusercontent.com/muxang/hybot-release/main/install.sh -o hybot-install.sh && bash hybot-install.sh --rollback
```

在线升级：bot 面板「设置」页一键升级（自动校验 sha256，systemd 拉起新版）。
