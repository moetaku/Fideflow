# GitHub Actions 与 Android 签名

`check.yml` 对 push、PR 和手动运行执行 Dart/Flutter 检查与测试、架构检查和 Rust 格式检查。
Rust 编译、clippy 和原生运行验收仍需配置对应平台的原生依赖后执行；此工作流不代表已完成全部平台验证。

## 全平台发布

`release.yml` 是统一入口，推送 `v<versionName>` 标签（例如 `v0.1.0`）后自动运行。
也可以在 Actions 中手动运行，但必须选择已存在的版本标签；分支运行会被拒绝。
标签必须与 `apps/fideflow_flutter/pubspec.yaml` 的版本一致。
五个平台均通过可复用工作流打包，统一入口调用同一套步骤。

| 目标 | Runner | 产物 |
| --- | --- | --- |
| Android arm64 / x86_64 | ubuntu-24.04（Linux NDK 工具链） | 签名 APK |
| macOS arm64 | macos-15 | ZIP、DMG（ad-hoc 签名，未公证） |
| macOS x86_64 | macos-15-intel | ZIP、DMG（ad-hoc 签名，未公证） |
| Windows x64 | windows-2022 | 安装器、便携 ZIP（无 Authenticode 签名） |
| Linux x86_64 | ubuntu-22.04 | AppImage、deb、rpm |
| Linux aarch64 | ubuntu-22.04-arm | AppImage、deb、rpm |
| iOS arm64 | macos-15 | 未签名 IPA，需自行签名安装 |

每个平台安装依赖、运行原生与 Flutter 构建、收集许可证并生成源码归档。
各 job 上传 `Fideflow-<platform>-<arch>-<version>` Actions artifact（保留 14 天），统一 `publish` job 仅在全部目标成功后运行：
检查七组产物及构建提交、校验文件哈希，再创建草稿 Release、上传所有文件、最后公开 Release。
上传失败时草稿保留，可重跑；已经公开的 Release 拒绝覆盖，请使用新版本标签。

只有 `publish` job 获得 `contents: write`；构建 job 使用只读权限。
发布流程通过可复用的 `check.yml` 执行同一提交的质量检查，全部通过后才开始平台打包；任一检查失败均阻止发布。
GitHub Actions 必须启用，组织策略须允许发布 job 使用写入权限。
ARM64 runner 也须在仓库的 Actions 配额/策略允许范围内。

Release 附件的应用名统一为 `Fideflow`，CPU 架构统一为 `x86_64`、`arm64`、`universal`；字段之间统一使用 `-`，保留 `x86_64` 内部下划线、版本号和扩展名中的点。包内平台元数据保留原生标识。
打包产物和 Release 附件使用 `Fideflow-<platform>-<arch>-<version>.<extension>`，例如 `Fideflow-android-universal-0.1.0+1.apk`、`Fideflow-windows-x86_64-0.1.0+1.zip` 和 `Fideflow-windows-x86_64-0.1.0+1.exe`。源码和清单在版本后添加用途后缀；同一组不再重复添加平台、架构或应用名。每组 `Fideflow-<platform>-<arch>-<version>-build.json` 保存映射与哈希，
原始平台构建清单保持不变。最终只发布一份 `Fideflow-all-universal-<version>-sources.tar.xz`，其中保留各平台原始源码归档；构建清单中的源码文件名和哈希对应汇总包内的文件。每组以及全局 `SHA256SUMS` 均针对实际下载文件名生成。
源码归档、许可证、构建清单和校验和不得在手动整理 Release 时删除。
macOS 没有额外生成独立应用清单的旧脚本，由统一整理步骤补充 `-build.json`。

此工作流提供构建和发布流程，不等同于已完成真机安装、系统集成或全部功能验收。

## 单平台打包验证

在 Actions 中选择对应工作流，点击 **Run workflow** 并选择需要验证的分支或标签：

| 工作流文件 | 验证目标 |
| --- | --- |
| `android-release.yml` | Android 签名 APK（原 macOS 构建入口） |
| `android-linux-release.yml` | Android 签名 APK（Linux，统一发布默认调用） |
| `macos-release.yml` | macOS arm64、x86_64 |
| `ios-release.yml` | iOS arm64 未签名 IPA |
| `linux-release.yml` | Linux x86_64、aarch64 |
| `windows-release.yml` | Windows x64 |

这些入口直接执行对应平台的依赖安装、构建、打包和产物整理，便于单独定位打包失败；
不等待全平台质量检查，也不会创建或更新 GitHub Release。全平台发布仍须通过质量检查。
版本从所选提交的 `pubspec.yaml` 读取；选择标签时仍校验标签与版本一致。
完成后在该次运行的 Artifacts 中下载 `Fideflow-<platform>-<arch>-<version>` 产物，保留 14 天。
Android 仍使用 `release` environment 的签名 Secrets，所选分支或标签须符合该 environment 的访问规则。
工作流入口需要先合入默认分支，才能在 Actions 页面显示手动运行按钮。

## Secrets

在 GitHub 仓库 Settings → Environments 中创建 `release`，为其配置以下 Secrets：

| 名称 | 内容 |
| --- | --- |
| `FIDEFLOW_ANDROID_KEYSTORE_BASE64` | 完整 JKS 文件的 Base64 编码 |
| `FIDEFLOW_ANDROID_KEYSTORE_PASSWORD` | 密钥库密码 |
| `FIDEFLOW_ANDROID_KEY_ALIAS` | 密钥别名 |
| `FIDEFLOW_ANDROID_KEY_PASSWORD` | 密钥密码 |

建议为该 environment 限制允许的发布标签/分支，并配置发布审核者。只有信任的代码才应获得签名凭证。
PR 检查工作流不读取签名 Secrets。手动运行也应选择受信任的分支。

macOS 上可执行 `base64 -i /安全路径/release.jks | pbcopy`，将剪贴板内容直接粘贴到 Secret；
Linux 可用 `base64 -w 0 /安全路径/release.jks`，不要把输出保存到仓库、日志或 Issue。
Base64 只是编码；不要提交编码后的密钥。保留密钥及密码的独立安全备份。

runner 仅在签名构建步骤恢复临时文件，构建退出及后续清理步骤都会删除文件。
密钥文件不得加入 artifact 或缓存，也不要启用会打印环境变量/命令展开的调试日志。

## 本地构建

本地可自行生成用于个人构建的密钥，官方更新包须保持使用同一发行签名：

```sh
keytool -genkeypair -keystore /安全路径/release.jks -alias fideflow-android \
  -keyalg RSA -keysize 3072 -validity 10000
export FIDEFLOW_ANDROID_KEYSTORE_PATH=/安全路径/release.jks
export FIDEFLOW_ANDROID_KEY_ALIAS=fideflow-android
# 通过本地安全方式设置密码环境变量，避免在 shell 历史中写入明文密码。
# FIDEFLOW_ANDROID_KEYSTORE_PASSWORD
# FIDEFLOW_ANDROID_KEY_PASSWORD
# macOS：保留原打包入口
tooling/release/android/package.sh
# Linux：使用独立入口
bash tooling/release/android/package-linux.sh
```

路径建议使用绝对路径；相对路径按 `apps/fideflow_flutter/android/app` 解析，与 Gradle 一致。
默认本地路径仍为 `apps/fideflow_flutter/android/fideflow-android.jks`，该文件应被 Git 忽略。

首次公开前必须确认所有待推送历史不包含密钥；新增删除提交无法移除旧提交中的密钥。
