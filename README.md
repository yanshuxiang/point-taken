# Point Taken

[中文](README.zh-CN.md)

Talk while you mark up your screen, and get your point across.

Point Taken is a macOS menu bar tool. Hold a shortcut, draw on your screen, and say what you mean. It lines up the screenshots, your marks and your words by time, and turns them into one illustrated note you can paste to a teammate or an AI in one go.

## Features

- **Talk and mark**: capture the screen, circle what matters, and your speech is transcribed and attached to the mark it belongs to.
- **Many pages in one go**: mark up several pages in a row; long pages can scroll and stitch into one tall image.
- **Review before sending**: zoom into each mark, edit its note, or drop a page.
- **Paste once**: the finished note pastes straight into a chat app, a document or an AI chat.
- **History**: everything you marked stays on your Mac and can be found again.

## Requirements

- macOS 13 or later (macOS 26 gets the Liquid Glass look)
- Xcode to build

## Build and install

```bash
./build.sh
```

The script builds the app, installs it to `/Applications/Point Taken.app` and opens it. On first run, macOS asks for Screen Recording, Microphone and Accessibility access.

## Where your data lives

- Marked sessions: `~/Point Taken/记录`
- Exports: `~/Point Taken/导出`
- Settings and speech models: `~/.point-taken`

Your records stay on your Mac. Speech is sent to a cloud service only if you choose one in Settings.

## License

[MIT](LICENSE)
