跨平台 Fideflow 安装包、原生依赖源码归档、构建清单与校验和。

- Android：已签名 APK。
- macOS：arm64、x86_64 ZIP/DMG，ad-hoc 签名，未经 Apple 公证。
- Windows：x64 安装器与便携 ZIP，未进行 Authenticode 签名。
- Linux：x86_64、aarch64 的 AppImage、deb、rpm，构建基线为 Ubuntu 22.04 / glibc 2.35。
- iOS：arm64 未签名 IPA，需要自行签名后安装。

每组 `*-sources.tar.xz` 是该组原生依赖的源码材料，请与对应安装包一起保留和分发。
本软件使用 LGPLv2.1 或更高版本授权的 FFmpeg，相关源码与构建材料随本 Release 提供。
各组件的许可证文本包含在安装包中。

全局 `SHA256SUMS` 可用于校验所有下载文件。每组 `-build.json` 记录构建提交、哈希、
原始文件名与 Release 下载文件名的映射；平台打包脚本生成的原始构建清单保持不变。

下载文件统一命名为 `Fideflow-<platform>-<arch>-<version>[-<kind>].<extension>`，例如 `Fideflow-android-universal-0.1.0+1.apk`。
源码附件统一为 `Fideflow-all-universal-<version>-sources.tar.xz`，包含各平台原始源码归档及构建信息。平台清单中的源码文件名与哈希对应汇总包内部文件；全局 `SHA256SUMS` 对应实际下载附件。
