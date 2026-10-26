#!/usr/bin/env bash
# macOS 一键打包：flutter build macos → 注入 Rust 核心 dylib → ad-hoc 签名。
# 前置条件：完整版 Xcode 已安装并 xcode-select 指向它；Rust 核心已编译
# （rust/target/release/libfqapi_core.dylib）。
#
# 用法：bash scripts/package_macos.sh [--open]
set -euo pipefail

# Homebrew 与 rustup 默认不在非交互 PATH 里；Flutter 按本项目约定位置加载；
# 完整版 Xcode（DEVELOPER_DIR）优先于 CLT，SwiftPM/CocoaPods 都需要它。
export PATH="/opt/homebrew/bin:/opt/homebrew/opt/rustup/bin:$PATH"
if [ -d "/Applications/Xcode.app" ]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi
if ! command -v flutter >/dev/null 2>&1; then
  [ -d "$HOME/tomato/tools/flutter/bin" ] && export PATH="$HOME/tomato/tools/flutter/bin:$PATH"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"
OPEN_AFTER=0
[ "${1:-}" = "--open" ] && OPEN_AFTER=1

echo "==> 1/4 编译 Rust 核心（aarch64-apple-darwin）..."
( cd "$APP_DIR/rust" && cargo build --release )

echo "==> 2/4 flutter build macos --release ..."
# macOS 26+ 的 lipo -verify_arch 只接受单个 arch（与手册矛盾，多 arch 一律
# 「requires exactly one input file」报错），而 Flutter 的 thinFramework 会用
# Xcode 注入的 ARCHS=X86_64 ARM64 去 verify，构建直接失败。这里通过
# flutter 官方的 FLUTTER_XCODE_* 透传机制把 ARCHS 固定为 arm64：
# xcodebuild ARCHS=arm64 → macos_assemble.sh -dDarwinArchs=arm64 → 单 arch verify。
# 产物为 arm64 单架构（本机即 Apple Silicon，无影响）。
# 同时 Xcode 27 最低支持 macOS 12 部署目标，模板的 10.15/10.14 一律抬到 12.0。
( cd "$APP_DIR" && FLUTTER_XCODE_ARCHS="arm64" \
    FLUTTER_XCODE_MACOSX_DEPLOYMENT_TARGET="12.0" \
    flutter build macos --release --target lib/main.dart )

APP="$APP_DIR/build/macos/Build/Products/Release/fqapp.app"
if [ ! -d "$APP" ]; then
  echo "错误：未找到 $APP" >&2
  exit 1
fi

echo "==> 3/4 注入 libfqapi_core.dylib 到 Contents/MacOS/ ..."
cp -f "$APP_DIR/rust/target/release/libfqapi_core.dylib" "$APP/Contents/MacOS/"
# cargo 默认把构建绝对路径写进 install_name；按可执行文件相对路径规范化，
# 避免拷贝机器/目录后出现解析歧义（虽然 dlopen 绝对路径不受影响）。
install_name_tool -id "@executable_path/libfqapi_core.dylib" \
  "$APP/Contents/MacOS/libfqapi_core.dylib"
# 校验注入后的可执行文件同目录加载路径（backend_transport 的第一候选）
ls -la "$APP/Contents/MacOS/" | head

echo "==> 4/4 ad-hoc 签名（本地运行用，无开发者证书）..."
codesign --force --sign - "$APP/Contents/MacOS/libfqapi_core.dylib"
codesign --force --sign - "$APP"
codesign --verify --verbose=1 "$APP"

SIZE=$(du -sh "$APP" | cut -f1)
echo "==> 完成：$APP ($SIZE)"
[ "$OPEN_AFTER" = "1" ] && open "$APP"
exit 0
