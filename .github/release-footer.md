## 安装 / Install

**macOS**（Apple 芯片，macOS 13 及以上 / Apple silicon, macOS 13+）
1. 下载 `PointTaken-{version}-macos-arm64.dmg`，打开后把「Point Taken」拖进「应用程序」。
2. 如果第一次打开时提示无法验证开发者：到「系统设置 → 隐私与安全性」，在下方点「仍要打开」。
   If macOS says it cannot verify the developer, open System Settings → Privacy & Security and click "Open Anyway".

**Windows**（Windows 10 2004 及以上，x64）
- 安装版 / Installer: `PointTaken-{version}-windows-x64-setup.exe`（装到当前用户，不需要管理员权限 / per-user, no admin rights）
- 免安装 / Portable: `PointTaken-{version}-windows-x64.zip`，解压后运行 `PointTaken.exe`
- 如果 SmartScreen 提示「Windows 已保护你的电脑」，点「更多信息 → 仍要运行」。
  If SmartScreen says "Windows protected your PC", click "More info → Run anyway".

转写需要 [uv](https://docs.astral.sh/uv/)，App 设置里可以一键安装。Speech needs [uv](https://docs.astral.sh/uv/); the app can install it for you.

## 校验 / Verify

```sh
shasum -a 256 -c PointTaken-{version}-macos-arm64.dmg.sha256                          # macOS
gh attestation verify PointTaken-{version}-macos-arm64.dmg -R yanshuxiang/point-taken  # 构建来源 / provenance
```

```powershell
(Get-FileHash PointTaken-{version}-windows-x64-setup.exe -Algorithm SHA256).Hash   # 和 .sha256 文件里的对比 / compare with the .sha256 file
```
