# 更新日志 / Changelog

格式参照 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循[语义化版本](https://semver.org/lang/zh-CN/)。
发布时，`## [<版本>]` 这一节的内容就是 GitHub Release 的说明（`.github/workflows/release.yml` 自动取），安装步骤和校验方法由工作流自动附在后面，这里不用写。
每一节先写中文，再写英文。

All notable changes to Point Taken are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0-beta.2] - 2026-11-19

macOS 和 Windows 第一次用同一个版本号、由 GitHub Actions 自动构建发布。

### 新增
- Windows 安装程序 `PointTaken-<版本>-windows-x64-setup.exe`：装到当前用户（不需要管理员权限），带开始菜单入口和卸载；免安装的 zip 照旧提供。
- 每个安装包都附带 GitHub 构建来源证明，可以用 `gh attestation verify <文件> -R yanshuxiang/point-taken` 核对它确实出自本仓库。

### 变化
- macOS 版包含 0.1.2 的全部修复。
- 两个平台的安装包这一版都还没有受信任的签名：macOS 版是 ad-hoc 签名、未公证；Windows 版未签名。从 0.1.x 升级的 macOS 用户需要在「系统设置 → 隐私与安全性」里重新允许一次屏幕录制、麦克风和辅助功能。

### Added
- Windows installer `PointTaken-<version>-windows-x64-setup.exe`: per-user install (no administrator prompt), Start menu entry and uninstaller. The portable zip is still provided.
- Every download has a GitHub build provenance attestation: `gh attestation verify <file> -R yanshuxiang/point-taken` confirms it was built from this repository.

### Changed
- First release where macOS and Windows share one version number, built and published by GitHub Actions.
- The macOS build includes every fix from 0.1.2.
- Neither build has a trusted signature yet: macOS is ad-hoc signed and not notarized, Windows is unsigned. macOS users upgrading from 0.1.x need to allow Screen Recording, Microphone and Accessibility once more in System Settings → Privacy & Security.

## [0.2.0-beta.1] - 2026-11-19

Point Taken 的第一个 Windows 测试版（只有 Windows）。

### 新增
- Windows 版（C# / WPF，.NET 8，自带运行时）：托盘图标、Alt+N 边说边画、检查窗口、历史记录、设置；转写和实时字幕用和 macOS 版同一套 Python 脚本，记录格式两边通用。
- `PointTaken.exe` 用自签名证书签名并加了时间戳（不是受信任的发布者，SmartScreen 会提示「未知发布者」）。

### 已知限制
- 同一页连续滚动时不会自动拼成长图。
- 只有简体中文界面。

### Added
- Point Taken for Windows (C# / WPF, .NET 8, self-contained): tray icon, Alt+N to talk and mark, review window, history and settings. Speech runs on the same Python scripts as on macOS, and records open on either platform.
- `PointTaken.exe` is signed with a self-signed certificate and timestamped (not a trusted publisher: SmartScreen shows "unknown publisher").

## [0.1.2] - 2026-11-18

### 修复
- 连上或断开蓝牙耳机、插拔外接麦克风、在系统设置里换了输入设备之后，开录提示「麦克风打不开」或录不到声音。现在每次开录都重新打开当前的麦克风。
- 录音中途换麦克风会自动接上新设备，录音不中断。
- 开录后没有声音进来时自动重试一次，还不行就明确提示，不再静默录一段空音频。
- 麦克风没启动时，结束后不再去转写空录音（以前会误报「服务返回错误」）。

### Fixed
- The microphone often failed to start after Bluetooth headphones connected or disconnected, a mic was plugged in or out, or the input device changed in System Settings. Each recording now opens the current microphone.
- Switching microphones mid-recording carries on with the new device instead of stopping.
- If no sound arrives after starting, the app retries once and then says so, instead of silently recording nothing.
- When the microphone never started, the app no longer tries to transcribe the empty recording.

## [0.1.1] - 2026-11-17

### 修复
- 去掉胶囊工具栏最左边的「画笔」按钮：它只是沿用上一次用过的工具，看起来像坏掉的重复按钮。现在工具栏只有自由画、矩形、圆圈、撤销、暂停；再点一次已选中的工具即回到正常操作。

### Fixed
- Removed the pen button at the left of the capsule toolbar: it only re-selected the last tool. The toolbar now has freehand, box, ellipse, undo and pause; click the selected tool again to go back to normal operation.

## [0.1.0] - 2026-11-16

Point Taken（懂你意思）首个版本（macOS，Apple 芯片，macOS 13 及以上）。

First release (macOS, Apple silicon, macOS 13 or later).

[Unreleased]: https://github.com/yanshuxiang/point-taken/compare/v0.2.0-beta.2...HEAD
[0.2.0-beta.2]: https://github.com/yanshuxiang/point-taken/compare/v0.1.2...v0.2.0-beta.2
[0.2.0-beta.1]: https://github.com/yanshuxiang/point-taken/releases/tag/v0.2.0-beta.1
[0.1.2]: https://github.com/yanshuxiang/point-taken/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/yanshuxiang/point-taken/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/yanshuxiang/point-taken/releases/tag/v0.1.0
