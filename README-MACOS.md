# fqapp-macos

> macOS 原生移植版 —— 番茄聚合客户端（小说 / 短剧 / 漫画 / **听书**）。
> 基于 [ch6vip/fqapp](https://github.com/ch6vip/fqapp)（GPL-3.0）的移植工作。

## 这是什么

上游 fqapp 提供 Android 与 Windows 客户端；本仓库把它的桌面适配层扩展到
macOS，产出可听书的 Apple Silicon 原生 `.app`：

- 复用上游全部桌面 UI / 数据 / 播放逻辑（`isWindowsDesktop` 总门控并入 macOS）
- 原生 WKWebView 登录窗（域名白名单 + Cookie 只读导入，替代 WebView2）
- CENC 流式解密核心（TTS/AI 朗读加密音源）移植到 macOS
- 修复 media_kit 在打包后找不到 `Mpv.framework` 的问题
- 一键打包脚本处理 macOS 26 `lipo` 单架构回归与 Xcode 27 部署目标下限

## 自行打包

要求：Apple Silicon Mac、完整版 Xcode、Flutter 3.44.6、Rust 1.99+、CocoaPods。

```bash
bash scripts/package_macos.sh          # 产物 build/macos/Build/Products/Release/fqapp.app
bash scripts/package_macos.sh --open   # 打包完直接启动
```

## 验证工具（tool/）

| 探针 | 用途 |
|---|---|
| `macos_core_probe.dart` | 免 Xcode 验证 Rust 核心（FFI + 真实上游搜索） |
| `macos_audio_probe.dart` | 听书数据链路（搜索 → 目录 → playinfo → CDN） |
| `macos_playback_probe.dart` | libmpv 实际播放音频 URL |
| `final_audio_check.dart` | 同进程端到端（解密代理 + 播放，双音源） |

## 说明

- 遵循上游 **GPL-3.0**；仅供个人学习与阅读使用，请支持正版
- 仅供个人本地构建，未分发二进制；如需上游功能更新，同步上游后重跑打包脚本
