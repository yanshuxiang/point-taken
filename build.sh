#!/bin/sh
# 编译并安装 Point Taken（懂你意思）到 /Applications，然后打开它。需要 Xcode。
exec "$(cd "$(dirname "$0")" && pwd)/app/macos/build-app.sh" "$@"
