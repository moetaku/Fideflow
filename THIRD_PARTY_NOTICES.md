# 第三方组件与许可证

本文记录 Fideflow 直接使用或随应用分发的主要第三方组件、来源及许可证。版本和源码归档以 [`tooling/native/sources.manifest.json`](tooling/native/sources.manifest.json) 为准；平台实际打包的依赖可能不同。组件仍受各自许可证约束，不因 Fideflow 的 Apache License 2.0 而改变。

## 原生媒体与系统依赖

| 组件 | 锁定版本 | 许可证 | 上游与许可证信息 | 仓库/发行包中的许可证材料 |
| --- | --- | --- | --- | --- |
| FFmpeg | 7.1.5 | LGPL-2.1-or-later | [源码](https://ffmpeg.org/releases/ffmpeg-7.1.5.tar.xz) · [许可说明](https://ffmpeg.org/legal.html) | 源码归档包含 `COPYING.LGPLv2.1`；构建配置见 `tooling/native/ffmpeg-components.txt` 和平台构建脚本 |
| libsoxr | 0.1.3 | LGPL-2.1-or-later | [固定版本源码](https://github.com/chirlu/soxr/archive/refs/tags/0.1.3.tar.gz) · [许可证](https://github.com/chirlu/soxr/blob/0.1.3/LICENCE) | 源码归档包含 `LICENCE` |
| PortAudio | 19.7.0 | MIT | [固定版本源码](https://files.portaudio.com/archives/pa_stable_v190700_20210406.tgz) · [许可证](https://github.com/PortAudio/portaudio/blob/master/LICENSE.txt) | 源码归档包含 `LICENSE.txt`；Linux 构建将其静态链接 |
| miniaudio | 0.11.25 | MIT-0（上游也提供 Unlicense 选项） | [固定版本源码](https://github.com/mackron/miniaudio/archive/refs/tags/0.11.25.tar.gz) · [许可证选项](https://github.com/mackron/miniaudio/blob/0.11.25/LICENSE) | 源码归档包含 `LICENSE`；Android/iOS 后端使用 miniaudio |
| SQLite（Windows 预编译库） | 3.54.0 | Public Domain | [官方预编译包](https://www.sqlite.org/2026/sqlite-dll-win-x64-3540000.zip) · [版权说明](https://www.sqlite.org/copyright.html) | Windows 发行包的 `licenses/sqlite.txt` 记录来源与校验和 |

FFmpeg 在本项目中按 LGPL 组件白名单构建，不启用 GPL 或 nonfree 组件；构建清单和脚本记录启用组件及配置。发行二进制时，应同时提供与该二进制对应的 FFmpeg 源码和构建信息，并遵循 FFmpeg 上游许可说明。仓库的发布流程会从锁定的源码归档生成对应源码材料；每次发布仍需确认归档与实际二进制相匹配。

## 其他直接组件

| 组件 | 许可证 | 来源与材料 |
| --- | --- | --- |
| Source Han Sans CN 字体 | SIL Open Font License 1.1 | [上游项目](https://github.com/adobe-fonts/source-han-sans)；许可证及所用字重/来源记录位于 `apps/fideflow_flutter/assets/fonts/SourceHanSans-LICENSE.txt` 和 `SourceHanSans-SOURCE.txt` |
| `ncm-api-rs` vendored SDK | WTFPL 2 | `ncm-api-rs` 是基于 [NeteaseCloudMusicApiEnhanced/api-enhanced](https://github.com/NeteaseCloudMusicApiEnhanced/api-enhanced) 的 Rust 实现；Fideflow 使用 [SPlayer-Dev/ncm-api-rs](https://github.com/SPlayer-Dev/ncm-api-rs) 的 fork [jinzhongjia/ncm-api-rs](https://github.com/jinzhongjia/ncm-api-rs)，固定在[提交 `5a5ced0`](https://github.com/jinzhongjia/ncm-api-rs/tree/5a5ced0f5feba6965f5cda718ebd6d73a9d3f26c)。许可证文件位于 `native/media_core/vendor/ncm-api-rs/LICENSE`；来源记录见 `UPSTREAM.json` |
| `native/media_core` 其余工作区 crates | MIT | [MIT 许可证文本](https://opensource.org/license/mit/)；项目声明位于 `native/media_core/Cargo.toml`，许可证正文位于 `native/media_core/LICENSE` |

> Rust 核心的自有 crates 继承工作区 MIT 声明，打包时收集 `native/media_core/LICENSE` 正文；`ncm-api-compat` 与项目主协议一致，使用根目录 Apache-2.0；vendored SDK 保持 WTFPL。应用的根目录 Apache 2.0 不改变这些组件的授权。

## 按平台生成的依赖清单

收集器默认离线使用本地 Cargo 源码缓存；Android/iOS/macOS/Windows 的打包入口显式启用
`--fetch-metadata`，允许 Cargo 获取锁文件固定的元数据/源码，避免全新 runner 缺少可选依赖材料。
Linux 沿用其发布依赖预取和离线检查流程。许可证补充文本本身随仓库保存，打包时不从任意网址下载。

Rust 传递依赖使用 `native/media_core/Cargo.lock` 锁定。五个平台的打包入口均调用
`tooling/release/licenses.py` 收集应用 Apache 2.0、Rust 核心 MIT、字体来源与许可证、Flutter SDK、
Rust 依赖许可证正文以及锁文件。Rust 清单按目标三元组保存，包含目标过滤后的工作区依赖闭包
（保守包含构建/开发依赖），不是精确的二进制符号清单；缺少依赖许可证正文会终止打包。
少数 crates.io 包省略的上游许可证由 `tooling/release/rust-license-evidence/` 补充，按包版本、
上游提交和正文 SHA-256 固定来源，保留原始版权声明。

| 平台 | 安装包中的材料目录 |
| --- | --- |
| Linux | `data/licenses/` |
| Windows | `licenses/` |
| macOS | `fideflow.app/Contents/Resources/licenses/` |
| Android | APK 的 `assets/licenses/`，AAB 的 `base/assets/licenses/` |
| iOS | `Runner.app/native-audio/licenses/` |

Flutter/Dart notices 保留在各平台 Flutter 生成的 `flutter_assets/NOTICES.Z`；桌面和 iOS 另提取为
`Dart-Flutter-NOTICES.txt`。Android 在签名前收集材料，打包后检查 APK/AAB 内的许可证和 Flutter notices，
不会在签名后修改安装包。各 Rust 目标的具体正文及清单位于 `rust-targets/<triple>/`。

五个平台均输出随发行版发布的 `*-sources.tar.xz` 与校验和。Linux 沿用项目及上游源码归档流程；
其他平台归档校验通过的原生上游源码压缩包、实际用于构建的源码树（包含构建脚本所作修改）及原生构建脚本/配置记录。
发布时应将源码归档与对应安装包一起上传到同一 Release；单独上传安装包不会自动分发旁边的源码归档。
这与 [FFmpeg 上游分发检查说明](https://ffmpeg.org/legal.html) 中关于对应源码和构建信息的要求保持一致。
