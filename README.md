# hybot-release

hybot（币安 U 本位合约 bot）的**升级产物仓库**：仅存放编译好的二进制、sha256 校验文件与安装脚本。
无源码、无任何密钥/配置。

## 安装 / 更新到最新版

```bash
curl -fsSL https://raw.githubusercontent.com/muxang/hybot-release/main/install.sh | bash
```

## 回滚上一版本

```bash
curl -fsSL https://raw.githubusercontent.com/muxang/hybot-release/main/install.sh | bash -s -- --rollback
```

在线升级：bot 面板「设置」页一键升级（自动校验 sha256，systemd 拉起新版）。
