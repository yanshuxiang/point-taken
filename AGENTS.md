# AGENTS.md

## 宣传视频相关文件

凡是制作 Point Taken 宣传视频相关的文件——文案、分镜、素材、录屏、配音、音乐、
生成视频的代码、渲染中间产物、成片——一律放在仓库根目录的 `video/` 里，
不要放到 `docs/`、`assets/`、`/tmp` 或仓库其他位置。

- `video/` 整个被 `.gitignore` 忽略，不进仓库；不要把其中任何文件 `git add -f` 进来，
  也不要为了视频去改仓库里的正式代码或资源（真需要改时先问用户）。
- 按层级放，不要往 `video/` 根目录直接扔文件：
  - `video/script/` 文案、分镜、配音稿、字幕稿
  - `video/assets/recordings/` 录屏等原始视频素材
  - `video/assets/images/` 截图、图标等图片素材
  - `video/assets/audio/` 配音、背景音乐、音效
  - `video/code/` 生成/剪辑视频的代码
  - `video/build/` 中间产物（缓存、临时帧、切片、草稿导出），可随时删
  - `video/output/` 最终成片，文件名带比例和版本，如 `pt-promo-16x9-v2.mp4`
- 需要更细分时在对应目录下建子目录；目录约定有变化时同步更新 `video/README.md` 和本节。
