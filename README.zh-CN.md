<div align="center">

<img src="assets/app/icon.png" alt="懂你意思" width="160" height="160">

# 懂你意思

[![Swift](https://img.shields.io/badge/Swift-5.9-F05138?logo=swift&logoColor=white)](app/macos/Package.swift)
[![macOS](https://img.shields.io/badge/macOS-13%2B-000000?logo=apple&logoColor=white)](#系统要求)
[![Python](https://img.shields.io/badge/Python-3.10%2B-3776AB?logo=python&logoColor=white)](scripts/.python-version)
[![sherpa-onnx](https://img.shields.io/badge/sherpa--onnx-1.13-6E40C9)](https://github.com/k2-fsa/sherpa-onnx)
[![License](https://img.shields.io/badge/License-MIT-13C26B)](LICENSE)

**一边说、一边在屏幕上圈圈画画，就能把你的意思讲清楚。**

[English](README.md) | 中文

</div>

<p align="center">
  <img src="docs/screenshots/04-live-captions.png" alt="边说边在页面上标注" width="800">
</p>

## 简介

懂你意思（Point Taken）是一个 macOS 菜单栏小工具：按住快捷键，在屏幕上标注，同时说出你想说的话。它会把截图、标注和你说的话按时间对齐，整理成一份带图的说明，一次粘贴给同事或 AI。

## ❤️ 赞助商

> [想出现在这里？](https://github.com/yanshuxiang/point-taken/issues)

<details open>
<summary>点击收起</summary>

<!--
  添加赞助商：把下面的占位内容换成：

  <a href="https://sponsor.example"><img src="assets/sponsors/name.png" alt="赞助商名称" width="100%"></a>

  **[赞助商名称](https://sponsor.example)** —— 一两句话介绍赞助商。

  横幅放在 assets/sponsors/（1200×200 的 PNG 或 SVG 效果最好）。多个赞助商之间用一行 --- 隔开。
-->

<a href="https://github.com/yanshuxiang/point-taken/issues"><img src="assets/sponsors/placeholder-banner.svg" alt="在这里展示你的品牌" width="100%"></a>

**在这里展示你的品牌** —— 懂你意思的用户每天都在给同事和 AI 讲清楚自己的想法。赞助本项目，你的横幅和简介就会出现在这里。

</details>

---

## 功能

- 🎙️ **边说边标**：截取屏幕，用画笔圈出重点，说话会自动转成文字，并挂到对应的标注上。
- 📑 **多页连续标注**：一次可以标好几页，长页面能自动滚动拼成长图。
- 🔍 **检查后再发**：发出前可以放大查看每一处标注、改说明、删页。
- 📋 **一次粘贴**：整理好的图文直接粘贴到聊天软件、文档或 AI 对话框里。
- 🗂️ **历史记录**：做过的标注都保存在本机，可以随时找回来。
- 🔒 **本地优先**：默认在本机转写语音，云端服务需要你自己打开。

## 截图

<table>
  <tr>
    <td width="50%" align="center"><img src="docs/screenshots/01-main-window-light.png" alt="主窗口（浅色）"><br><sub>主窗口（浅色）</sub></td>
    <td width="50%" align="center"><img src="docs/screenshots/02-main-window-dark.png" alt="主窗口（深色）"><br><sub>主窗口（深色）</sub></td>
  </tr>
  <tr>
    <td align="center"><img src="docs/screenshots/03-shortcut-hints.png" alt="第一次开始时的快捷键提示"><br><sub>第一次开始：快捷键一目了然</sub></td>
    <td align="center"><img src="docs/screenshots/04-live-captions.png" alt="标注时实时出字幕"><br><sub>边标边说，文字实时出现</sub></td>
  </tr>
  <tr>
    <td align="center"><img src="docs/screenshots/05-drawing.png" alt="画笔、画框、画圈"><br><sub>画笔、画框、画圈</sub></td>
    <td align="center"><img src="docs/screenshots/06-pages-saved.png" alt="已存好几页"><br><sub>存一页，接着标下一页</sub></td>
  </tr>
  <tr>
    <td align="center"><img src="docs/screenshots/07-review.png" alt="检查窗口"><br><sub>发出前逐条检查</sub></td>
    <td align="center"><img src="docs/screenshots/08-pasted.png" alt="粘贴到 AI 对话框"><br><sub>一次粘贴到 AI 对话框</sub></td>
  </tr>
  <tr>
    <td align="center"><img src="docs/screenshots/09-history.png" alt="历史记录"><br><sub>在历史记录里找回以前的标注</sub></td>
    <td align="center"><img src="docs/screenshots/10-settings-models.png" alt="模型与 API 设置"><br><sub>本地或云端转写，随你选</sub></td>
  </tr>
</table>

## 怎么用

1. 按 <kbd>⌥</kbd> <kbd>N</kbd>，屏幕上出现一个小胶囊，开始收音。
2. 按住 <kbd>⌃</kbd> 在屏幕上画，同时说话。每一笔、每一句都带着时间。
3. 再按 <kbd>⌥</kbd> <kbd>N</kbd> 存下这一页，切到下一页接着标；长页面可以滚动拼成长图。
4. 按 <kbd>⌥</kbd> <kbd>↩</kbd>。懂你意思会把每句话对到你说这句话时正在画的那处标注上。
5. 说明会以图片加文字的形式粘到当前在前台的应用里，检查一下再发送。

### 默认快捷键

| 快捷键 | 作用 |
| --- | --- |
| <kbd>⌥</kbd> <kbd>N</kbd> | 开始标注；标注中按下则存这一页，再切下一页 |
| 按住 <kbd>⌃</kbd> | 画笔 |
| <kbd>⌃</kbd> <kbd>⇧</kbd> | 画框 |
| <kbd>⌃</kbd> <kbd>⌥</kbd> | 画圈 |
| <kbd>⌥</kbd> <kbd>Z</kbd> | 撤销一笔 |
| <kbd>⌥</kbd> <kbd>↩</kbd> | 完成并粘贴 |
| <kbd>⌥</kbd> <kbd>Esc</kbd> | 取消 |

快捷键可以在 **设置 → 快捷键** 里修改。

## 语音转写

在 **设置 → 模型与 API** 里选择转写服务。

| 选项 | 在哪里运行 | 说明 |
| --- | --- | --- |
| 本机（默认） | 本地，基于 [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) | 默认用 SenseVoice Small（中、英、日、韩、粤语），第一次使用时下载。 |
| 火山引擎、阿里云百炼（Qwen3-ASR）、OpenAI、Groq | 云端 | 用你自己的 API Key，Key 保存在 macOS 钥匙串里。 |

语音检测用的是 [Silero VAD](https://github.com/snakers4/silero-vad)，模型随仓库放在 `models/` 里，第一次录音不用额外下载。

## 系统要求

- macOS 13 或更新版本（在 macOS 26 上会使用新的液态玻璃外观）
- 编译需要 Xcode（用的是 Xcode 自带的工具链，系统自带的命令行工具太旧，编不过）
- 运行时语音脚本需要 [uv](https://docs.astral.sh/uv/)。如果 `PATH` 里没有，App 会提示帮你装到 `~/.point-taken/bin`。

## 编译和安装

```bash
./build.sh
```

脚本会编译并安装到 `/Applications/Point Taken.app`，然后启动它。第一次运行时，系统会请求屏幕录制、麦克风和辅助功能权限。

要用别的 Xcode，先设置 `DEVELOPER_DIR`：

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer ./build.sh
```

## 数据存放在哪里

| 内容 | 位置 |
| --- | --- |
| 标注记录 | `~/Point Taken/记录` |
| 导出文件 | `~/Point Taken/导出` |
| 设置和转写模型 | `~/.point-taken` |

记录都保存在你的电脑上。只有在设置里选了云端语音服务时，语音才会发送到云端转写。

## 开发

### 目录结构

```
app/macos/              App 的 Swift 包（SwiftPM）
  Sources/PointTakenApp   AppKit 界面：Capture/（胶囊、画笔、翻页、检查、历史）、
                          App/（菜单、快捷键、模型下载）、Settings/、Onboarding/
  Sources/PointTakenCore  配置、路径、脚本调用、记录存档和导出（不含界面）
  Sources/PointTakenObjC  接住 AVFoundation 抛出的 Objective-C 异常
  Tests/                  PointTakenCore 的 Swift 单元测试
  build-app.sh            打包 .app 并安装
scripts/                App 通过 uv 调用的 Python 脚本
  transcribe.py           带时间戳的语音转写（先做语音检测，再交给选定的模型）
  board_live.py           标注过程中的实时字幕
  polish.py               可选：本地整理转写文字（MLX，Apple 芯片）
  polish_cloud.py         同样的整理，交给你配置的云端模型
  *_models.json           模型清单
models/                 随仓库附带的 Silero VAD 模型
assets/                 App 图标和赞助商横幅
tests/                  Python 测试（pytest）
docs/                   设计笔记、调研记录和截图
```

Swift 部分负责界面、截屏和存储；语音相关的工作交给 Python 脚本。脚本在文件开头声明自己的依赖（[PEP 723](https://peps.python.org/pep-0723/)），`uv run` 会自动装好，不需要单独安装。Python 版本固定在 `scripts/.python-version`。

### 运行测试

Swift：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path app/macos
```

Python（单个文件）：

```bash
uv run --with numpy --with pytest pytest tests/test_asr_select.py -q
```

每次跑 Python 测试都会用一个临时的 `POINT_TAKEN_HOME`，不会碰到你真正的 `~/.point-taken`。会在屏幕上打开 App 窗口的测试默认跳过，设置 `POINT_TAKEN_GUI_TESTS=1` 才会跑。

## 许可证

[MIT](LICENSE)
