# Point Taken for Windows（懂你意思）

Windows 版用 C# / WPF（.NET 8）重写了 macOS 版的界面和系统交互；转写、实时字幕、模型下载仍由同一套 Python 脚本（`scripts/`）完成，记录格式（`页面.json`、`时间线.json`、`说明.md`……）和 macOS 版相同，两边的记录可以互相打开。

## 用法

1. 解压 `PointTaken-<版本>-windows-x64.zip`，运行 `PointTaken.exe`。启动后只在任务栏右下角的通知区域出现图标。
2. 第一次用：右键图标 → 设置 → 模型与 API，下载 **SenseVoice Small**（约 230 MB，本机识别，不上传录音）。错字多的话，同一页可以「下载并改用」**Fun-ASR-Nano**（约 950 MB，错字更少，转写时多占约 2 GB 内存）；也可以填豆包、阿里云百炼或 OpenAI 兼容服务的密钥，改用云端模型。
3. 按 <kbd>Alt</kbd>+<kbd>N</kbd> 开始。屏幕顶部出现胶囊：绿点表示在录音，旁边是你刚说的话。
4. 点胶囊上的画笔（自由画 / 矩形 / 圆圈）画一笔，或者按住 <kbd>Ctrl</kbd> 画、按住 <kbd>Ctrl</kbd>+<kbd>Shift</kbd> 画矩形；松开就回到正常点击，可以继续操作、翻页、滚动。按住键时按下鼠标就是在画，不会点到或拖动下面的内容。
   - 画了标记的那一页只截标记所在的窗口（设置 → 通用 → 截图范围，可改成整个屏幕）。
   - 胶囊上的「截图」：不画也把当前窗口存成一页。
   - 胶囊上的「麦克风」：关掉后只记画的、不录音；再打开时另起一段录音，转写里也另起一段。「暂停」则是语音和画面都停。
   - 没画标记的画面默认不留页；想让说过话的画面也自动截一张，打开 设置 → 通用 → 没画的画面也留页。
5. 点「完成」，检查窗口打开：勾选要交给 AI 的页面、调顺序、补画或给标记写说明、改全文。
6. 「复制说明和图片路径」后粘贴给 AI，或者选好目标窗口点「粘贴（不发送）」。

需要：Windows 10 2004 或更新（自己的窗口不出现在截图里依赖它）、[uv](https://docs.astral.sh/uv/)（设置里可以一键安装；首次转写时会自动准备 Python 和依赖）。

## 数据放在哪

- 记录：`%USERPROFILE%\Point Taken\连标\<时间>\`（设置里可以改），永久保留，删除时移到回收站。
- 导出：`%USERPROFILE%\Point Taken\连标导出\`。
- 配置、模型、密钥：`%USERPROFILE%\.point-taken\`（密钥用 Windows 数据保护加密在 `secrets.dat`）。设环境变量 `POINT_TAKEN_HOME` / `POINT_TAKEN_WORKSPACE` 可以整体搬到别的盘。

## 开发

```powershell
powershell -ExecutionPolicy Bypass -File app\windows\build.ps1        # 测试 + 打包 dist\PointTaken-<版本>-windows-x64.zip
dotnet test app\windows\PointTaken.Core.Tests                        # 只跑单元测试
dist\PointTaken-<版本>-windows-x64\PointTaken.exe --self-check <目录>   # 截图排除、记录文件、界面渲染、麦克风自检
dist\...\PointTaken.exe --live-probe <wav> <目录>                       # 用所选模型跑一遍实时字幕和整段转写
```

| 目录 | 内容 |
| --- | --- |
| `PointTaken.Core/` | 与界面无关：记录格式、交付文字、笔迹几何、页面判断、脚本调用（有单元测试） |
| `PointTaken.App/Capture/` | 标注会话、胶囊、画笔层、截图、录音、实时字幕 |
| `PointTaken.App/Review/` | 检查窗口和标记画布 |
| `PointTaken.App/History/`、`Settings/` | 历史记录、设置 |
| `PointTaken.App/System/` | Win32 互操作、快捷键、粘贴、密钥、自检 |

## 和 macOS 版的差别

界面按 macOS 版逐项对齐：胶囊（尺寸、圆角、按钮、提示小胶囊、警告卡）、托盘菜单（识别模型子菜单）、检查窗口（侧栏、工具栏图标组、两列浮动工具、放大标注、标记 / 按时间 / 全文）、历史记录（按天分组、搜索、多选删除）、设置（通用 / 模型与 API / 快捷键 / 权限）、提示框、滚动条。文案与 macOS 版一致，只有平台名词按 Windows 改：菜单栏 → 托盘，访达 → 资源管理器，废纸篓 → 回收站，⌘ / ⌥ → Ctrl / Alt。

刻意不同的地方：

- 窗口右上角是 Windows 的最小化 / 最大化 / 关闭按钮，没有 macOS 左上角的红黄绿按钮。
- 画笔按住键默认是 Ctrl / Ctrl+Shift（macOS 是 ⌥ / ⌥⇧）：Windows 上单按 Alt 会打开前台程序的菜单栏。
- 默认转写模型是本机的 SenseVoice Small（macOS 默认用苹果系统识别，Windows 上没有）；设置里没有「语音识别」权限一项。
- 截图默认只截标记所在的窗口（macOS 版截整个屏幕）；没画的画面默认不留页（macOS 版会把说过话的画面留成未勾选的一页）。
- 胶囊多了「截图」和「麦克风」两个按钮。原始录音存成设备采样率的 16 位单声道（macOS 版是 32 位浮点、设备声道数），大约是原来的四分之一大。
- 界面语言只有简体中文。

还没做：同一页连续滚动自动拼成长图（「拆开长图」菜单项暂时灰着）。
