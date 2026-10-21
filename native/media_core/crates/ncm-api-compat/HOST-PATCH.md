# Fideflow NCM 兼容库

当前上游快照（同步日期：2026-10-19）：

- Repository: https://github.com/jinzhongjia/ncm-api-rs
- Branch: `feat/sync-upstream-2026-10`
- Commit: `5a5ced0f5feba6965f5cda718ebd6d73a9d3f26c`
- Pin and checksums: [UPSTREAM.json](UPSTREAM.json)

`vendor/ncm-api-rs` 中的上游 SDK 是未经修改的 Git 快照。`UPSTREAM.json` 记录其分支、提交以及
`git archive --format=tar <commit>` 生成内容的 SHA-256。Host 补丁、生成式重写和格式调整均不会应用于该目录。

此独立 crate 负责 Host 专属行为：
- 可失败的无 Cookie HTTP 初始化，以及逐请求设备身份。
- 共享 HTTP 连接池、有界流式响应（包括 key/token 初始化）和可选的来源 Date 元数据。
- 请求级协议缓存；账号/设备变更会重置会话状态。
- 类型化的 `ResponseTooLarge` 错误，以及保留短信业务错误正文。
- 安全的歌单分页和设备名称上传校验。
- 登录响应适配，将来源 Date 传递给 Host。

上游没有提供可注入传输层或读取原始响应元数据的钩子。因此，此 crate 拥有一套基于固定版本请求实现派生的
传输层，并通过依赖复用上游的加密、工具函数和协议选项类型。未修改的 Host endpoint 实现通过显式路径模块
直接包含上游源码；本地仅实现五个适配过的 endpoint。查询和错误类型为本地定义，用于将这些 endpoint 接入
有界传输层。本设计有意依赖固定 SDK 的源码布局；更新时必须同时编译并测试这两个 crate。派生自
ncm-api-rs 的上游源码保留 WTFPL 许可和许可证文本；兼容层使用项目根目录的 Apache-2.0 许可。

Host 依赖此兼容 crate，且不启用 server feature。
工作区的 Cargo.lock 固定链接依赖关系；上游 Cargo.lock 保持不变，用于固定独立 SDK/server 构建。
