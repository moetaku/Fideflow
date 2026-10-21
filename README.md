# Fideflow

Fideflow 是一个使用 Flutter 构建界面、Rust 实现媒体核心的音乐客户端：支持在线目录、搜索、多账号、
队列与恢复、歌词与音质选择、缓存与预缓存、输出设备与播放效果、系统媒体控制。关闭窗口保留播放，
退出应用停止。

> Fideflow 是第三方开源客户端，与网易云音乐官方无关，不提供绕过 DRM、付费内容或地域限制的能力；
> 使用本项目访问第三方服务时，请自行遵守其服务条款与当地法律法规。

## 功能

- **浏览**：推荐、歌单广场、排行榜、歌手/专辑/歌单详情、搜索、心动模式
- **账号**：扫码或短信登录、多账号切换与恢复、凭证保存在系统安全存储
- **播放**：队列编辑与播放模式、暂停恢复、歌词、音质选择、音频/歌词/封面缓存与自动预缓存、
  输出设备与独占模式、淡入淡出与响度平衡、重采样、系统媒体控制与全局快捷键
- **界面**：15 款内置主题与自定义主题、桌面与移动端响应式布局、英文与简体中文

## 平台支持

| 平台 | 最低版本 | 架构 |
| --- | --- | --- |
| macOS | 12.0 | arm64 / x86_64 |
| Windows | 10 2004 | x64 |
| Linux | 主流发行版 | 仅本机架构（x86_64 / aarch64） |
| Android | 7.0（API 24） | `arm64-v8a` / `x86_64` |
| iOS | 15.0 | ARM64 真机 / 模拟器 |

## 环境要求

- Flutter **3.47.5**（Dart SDK `^3.12.2`）与含 rustfmt/clippy 的 Rust 工具链
- 原生依赖从源码构建，版本固定于 `tooling/native/sources.manifest.json`：
  FFmpeg 7.1.5、PortAudio 19.7.0、miniaudio 0.11.25、libsoxr 0.1.3
- 各平台额外依赖：
  - macOS：Xcode Command Line Tools、Homebrew、CMake、NASM、pkg-config（打包需完整 Xcode）
  - Windows：MSVC、Windows SDK、CMake、Python 3、NASM、MSYS2
  - Linux：系统开发包、Python 3.10+
  - Android：Android SDK、NDK 28.2.13676358、CMake、make、Python 3
  - iOS：macOS、完整 Xcode、CMake、make、Python 3

首次运行前必须先构建目标平台的原生依赖；之后 Flutter 构建会增量刷新 Rust 库。以下命令均在仓库根目录
执行，各平台步骤独立选择。

## 构建与运行

### macOS

```sh
./tooling/bootstrap-macos.sh
tooling/native/macos/build.sh --arch arm64    # Intel 使用 x86_64
cd apps/fideflow_flutter && flutter run -d macos
```

首次安装 Command Line Tools 后需重新运行初始化脚本；当前终端找不到 `cargo` 时执行
`source "$HOME/.cargo/env"`。

### Windows

```powershell
./tooling/bootstrap.ps1
./tooling/native/windows/build.ps1
cd apps/fideflow_flutter; flutter run -d windows
```

运行时保留完整的 `build/windows/x64/runner/Release` 目录；如需直接构建发行版可改用
`flutter build windows --release`。

### Linux

```sh
tooling/bootstrap-linux.sh --for build
tooling/release/linux/install-local.sh      # 构建并安装到 ~/.local/opt/fideflow/<版本>
```

`install-local.sh` 同时注册桌面项；版本已安装时拒绝覆盖，需先更新
`apps/fideflow_flutter/pubspec.yaml` 的版本。只调试不安装时可执行
`tooling/native/linux/build.sh all --arch host && cd apps/fideflow_flutter && flutter run -d linux`。

### Android

```sh
rustup target add aarch64-linux-android x86_64-linux-android
python3 tooling/native/mobile/build.py deps --platform android
python3 tooling/native/mobile/build.py fetch
python3 tooling/native/mobile/build.py build --platform android
cd apps/fideflow_flutter && flutter run -d <device-id>
```

### iOS

```sh
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
python3 tooling/native/mobile/build.py deps
python3 tooling/native/mobile/build.py fetch
python3 tooling/native/mobile/build.py build --platform ios
cd apps/fideflow_flutter && flutter build ios --simulator --debug
```

真机安装需在 Xcode 中配置开发者证书与描述文件。

## 打包

版本取自 `apps/fideflow_flutter/pubspec.yaml` 的 `version: x.y.z+N`，产物输出到
`build/release/<platform>/<version>+<build>/`。

| 平台 | 命令 | 产物 |
| --- | --- | --- |
| Android（macOS 环境） | `tooling/release/android/package.sh` | APK |
| Android（Linux 环境） | `bash tooling/release/android/package-linux.sh` | APK |
| iOS | `tooling/release/ios/package.sh` | 未签名 IPA |
| Linux | `python3 tooling/release/linux/package.py` | AppImage、deb、rpm |
| macOS | `tooling/release/macos/package.sh` | `.app`、ZIP、DMG（ad-hoc 签名，未公证） |
| Windows | `./tooling/release/windows/package.ps1` | 便携 ZIP；安装 Inno Setup 后生成安装器 |

Android 签名通过环境变量配置，详见 [GitHub Actions 与签名配置](.github/RELEASE.md)；macOS 公开发布前需自行完成
Developer ID 签名与公证。Android、iOS 与 macOS 脚本支持 `--skip-native-build` 复用已构建的原生依赖，
Windows 对应开关为 `-SkipBuild`。

GitHub Actions 的全平台打包与统一 Release 上传通过推送版本标签触发；runner、签名限制、
Secrets 配置与下载文件说明见 [发布流程](.github/RELEASE.md)。

## 使用

- 首次启动后在登录页扫码（桌面）或使用短信验证码（移动）登录，可添加多个账号并随时切换。
- 点击歌曲或歌单即可开始播放；播放条支持暂停、切歌、调整音量与查看队列，详情页可编辑队列和切换播放模式。
- 设置中可调整主题与强调色、在线音质（按账号保存）、重采样、预缓存数量、缓存配额与输出设备。
- 关闭窗口继续播放，退出应用或在 macOS 按 Cmd+Q 才会停止。

数据保存在 macOS `~/Library/Application Support/Fideflow`（缓存 `~/Library/Caches/Fideflow`）、
Linux `$XDG_DATA_HOME/Fideflow`、Windows `%LOCALAPPDATA%\Fideflow`；清理缓存不会删除账号与设置。

## 配置项

| 变量 | 说明 |
| --- | --- |
| `FF_PROVIDER_MODE` | Provider 模式：`host`（默认，进程内 NCM Host）或 `remote`（显式远端覆盖） |
| `FF_PROVIDER_BASE_URL` | `remote` 模式的服务地址，默认 `http://127.0.0.1:8000` |
| `FF_MEDIA_CORE_LIBRARY` | 指定原生 ABI 测试/运行加载的动态库路径 |
| `FF_ALLOW_MISSING_NATIVE` | 允许缺少原生依赖时运行（Debug 与 CI 用，Release 缺失即失败） |
| `FF_SKIP_NATIVE_EMBED` | 跳过 macOS 原生库嵌入阶段，仅构建界面 |
| `ANDROID_SDK_ROOT` / `ANDROID_NDK_HOME` | Android 自定义 SDK / NDK 路径 |

主题、音质、重采样、预缓存与缓存配额等运行时设置均在应用内维护，无需环境变量。

## 致谢

感谢 [NeteaseCloudMusicApiEnhanced/api-enhanced](https://github.com/NeteaseCloudMusicApiEnhanced/api-enhanced) 提供原始 Node.js API 项目，以及 [SPlayer-Dev/ncm-api-rs](https://github.com/SPlayer-Dev/ncm-api-rs) 将其实现为 Rust SDK。Fideflow 使用的是该 SDK 的 fork [jinzhongjia/ncm-api-rs](https://github.com/jinzhongjia/ncm-api-rs)，固定在提交 [`5a5ced0`](https://github.com/jinzhongjia/ncm-api-rs/tree/5a5ced0f5feba6965f5cda718ebd6d73a9d3f26c)。相关代码保留各自的许可证和来源记录，详见[第三方组件与许可证](THIRD_PARTY_NOTICES.md)。

## 许可证

本项目以 [Apache License 2.0](LICENSE) 发布；Rust crate 的许可证声明以各自的 `Cargo.toml` 为准。
FFmpeg（LGPL，按白名单组件构建）、PortAudio、libsoxr、miniaudio 及
`native/media_core/vendor/ncm-api-rs`（WTFPL）等第三方组件遵循各自许可证，各平台发行包均收集许可证文本，并输出需随二进制一起发布的对应源码归档。版本、上游链接和许可证材料位置见[第三方组件与许可证](THIRD_PARTY_NOTICES.md)。
