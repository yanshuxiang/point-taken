# 更新日志 / Changelog

格式参照 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循[语义化版本](https://semver.org/lang/zh-CN/)。
发布时，`## [<版本>]` 这一节的内容就是 GitHub Release 的说明（`.github/workflows/release.yml` 自动取），安装步骤和校验方法由工作流自动附在后面，这里不用写。
每一节先写中文，再写英文。

All notable changes to Point Taken are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - 2026-11-24

第一个同时提供 macOS 和 Windows 的正式版。相对 0.1.2：新增 Windows 版（安装程序和免安装 zip），两个平台由 GitHub Actions 用同一个版本号构建发布；Windows 版根据 0.2.0 测试版用户的反馈做了下面这些修改，并用 10 分钟真人录音的完整会话实测过。

The first release for both macOS and Windows. Since 0.1.2: Point Taken for Windows (installer and portable zip), and both platforms built and published by GitHub Actions under one version number. The Windows changes below come from feedback on the 0.2.0 betas and were tested in full 10-minute sessions with real speech.

### 新增
- Windows：胶囊上新增「截图」按钮，不画标记也能把当前窗口存成一页。
- Windows：胶囊上新增「麦克风」按钮。关掉后只记画的、不录音；再打开时另起一段，实时字幕和完整转写里都分段。
- Windows：设置 → 通用新增「截图范围」（标记所在的窗口 / 整个屏幕）和「没画的画面也留页」。
- Windows：设置 → 模型与 API 推荐更准确的本机模型 Fun-ASR-Nano（约 950 MB）。在一段 2 分 45 秒的中文测试录音上，错字率从 SenseVoice 的 10.4% 降到 6.3%。

### 变化
- Windows：画了标记的那一页默认只截标记所在的窗口，不再截整个屏幕；在菜单上画时会连同它所属的程序窗口一起截。
- Windows：只说过话、没画标记的画面默认不再自动截图留页，记录里的文件少了很多。
- Windows：原始录音改为设备采样率的 16 位单声道，大小约为原来的四分之一（8 分钟约 46 MB）；转写完成后删掉重复的录音副本。
- 转写：只在停顿或最安静的地方切分录音，片段之间不再重叠；实时字幕在停顿处断句，不再每 15 秒硬切一刀。

### 修复
- Windows：按住 Ctrl 画时，按下鼠标的一刻就由画笔接管，不会再拖动或点到下面程序里的图片和文字。
- Windows：内存占用。10 分钟会话实测稳定在 122–198 MB，不再随时间增长；之前曾有用户报告 8 分钟涨到 359 MB。
- Windows：设置里的「识别语言」以前没有传给模型，模型会自己猜语言，把短句或带口音的话认成别的语言。现在按设置识别。
- 转写：词被从中间切开时出现的重复字和多余句号（如「横坐标和。和一个」）。

### Added
- Windows: a 截图 (screenshot) button on the capsule saves the window in front as a page without marking it.
- Windows: a microphone button on the capsule. While it is off, marks are still kept but nothing is recorded; turning it back on starts a new take, which is a paragraph of its own in the live and the final text.
- Windows: Settings → General → screenshot area (the marked window, or the whole screen), and an option to keep screens that were only talked over.
- Windows: Settings → Models offers Fun-ASR-Nano (about 950 MB) as the more accurate local model. On a 2:45 Chinese test recording its character error rate was 6.3%, against 10.4% for SenseVoice.

### Changed
- Windows: a marked page shows only the window(s) under the marks instead of the whole screen; a mark on a menu keeps the app the menu belongs to.
- Windows: screens that were only talked over no longer become pages by default, so a record holds far fewer files.
- Windows: the recording is 16-bit mono at the device's rate, about a quarter of its former size (about 46 MB for 8 minutes); the duplicate 16 kHz copy is removed once transcription is done.
- Transcription: speech is cut only at pauses or at its quietest moment, never with overlapping pieces; live captions break at pauses instead of every 15 seconds.

### Fixed
- Windows: holding Ctrl to draw takes the mouse press at once, so it no longer drags or clicks pictures or text in the app below.
- Windows: memory use. Ten-minute sessions now stay between 122 and 198 MB with no growth over time; one user had reported 359 MB after 8 minutes.
- Windows: the recognition-language setting was never passed to the model, which guessed the language and sometimes took short or accented speech for another one.
- Transcription: duplicated characters and stray full stops where a word had been cut in two.

### 已知限制
- 两个平台的安装包都还没有受信任的签名：macOS 版是 ad-hoc 签名、未公证；Windows 版未签名，SmartScreen 会提示「未知发布者」。从 0.1.x 升级的 macOS 用户需要在「系统设置 → 隐私与安全性」里重新允许一次屏幕录制、麦克风和辅助功能。
- Windows 版只有简体中文界面；同一页连续滚动时不会自动拼成长图。

### Known limitations
- Neither build has a trusted signature yet: macOS is ad-hoc signed and not notarized; Windows is unsigned, so SmartScreen shows "unknown publisher". macOS users upgrading from 0.1.x need to allow Screen Recording, Microphone and Accessibility once more in System Settings → Privacy & Security.
- The Windows interface is in Simplified Chinese only, and a page scrolled in place is not stitched into one long picture.

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

[Unreleased]: https://github.com/yanshuxiang/point-taken/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/yanshuxiang/point-taken/compare/v0.1.2...v0.2.0
[0.2.0-beta.2]: https://github.com/yanshuxiang/point-taken/compare/v0.1.2...v0.2.0-beta.2
[0.2.0-beta.1]: https://github.com/yanshuxiang/point-taken/releases/tag/v0.2.0-beta.1
[0.1.2]: https://github.com/yanshuxiang/point-taken/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/yanshuxiang/point-taken/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/yanshuxiang/point-taken/releases/tag/v0.1.0
