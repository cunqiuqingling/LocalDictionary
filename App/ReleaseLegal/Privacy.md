# Privacy

本文描述当前源码版本的实际数据边界。LocalDictionary 没有项目自有服务器；本地词典在设备上运行，可选 AI 功能会连接用户配置的第三方服务。

## 本地词典

- 本地词典查询和 SQLite 索引在设备上执行。
- `managedLocal` 导入会把用户明确选择的 MDX 复制到本机 Application Support 的 App 托管目录；原始导入文件不会因托管副本的建立或移除而被修改。
- App 不自动上传词典文件或词典正文。
- 开发者本机的 legacy 私有配置只从 `~/Library/Application Support/LocalDictionary/LegacyConfig/local.json` 读取，不进入 App Bundle。
- 仓库和 App Bundle 均不包含商业词典。

## AI 请求

只有用户主动触发 AI 功能，或用户明确启用了完整英文句子的自动分析时，LocalDictionary 才会向所选 Provider 发送请求。请求可能包含：

- 当前单词、短语或句子；
- 生成结构化响应所需的系统提示；
- 所选模型和响应格式参数。

LocalDictionary 不主动向 AI Provider 发送整本词典内容、本地词典路径、Obsidian 笔记正文、剪贴板历史、页面中未选中的其他内容或其他查询历史。用户的 API Key 直接用于访问其所选 Provider，不会发送给项目作者。

第三方 Provider 可能有自己的日志、保留、训练、计费和隐私政策；LocalDictionary 无法控制或保证这些行为。使用前请查看对应 Provider 的条款。

## API Key 与 Provider 配置

- API Key 存储在 macOS Generic Password Keychain。
- Provider 名称、URL、模型、开关和顺序等非敏感配置存储在本机 UserDefaults。
- 项目不包含预置 API Key。
- 自动测试使用隔离设置、模拟网络和测试凭据边界，不读取生产 Keychain 项。

## AI 缓存

- 结构化 AI 结果缓存在 `~/Library/Application Support/LocalDictionary/AI/ai-cache.sqlite`。
- 当前缓存上限为 256 条，超出后按创建时间移除较旧记录。
- 缓存键隔离请求模式、规范化查询信息、Provider、Base URL 摘要、模型、提示版本、响应策略和 Schema 版本。
- 结构化缓存结果可能包含当前查询原文及 AI 返回的解释或分析。
- 用户可以在 AI 设置中清除全部缓存，也可以对当前查询清除对应缓存。
- 缓存不会自动上传到项目服务器。

## 遥测与日志

当前版本没有遥测、用户分析、广告、自动崩溃上传或自动更新服务。Release 构建不记录查询正文。Debug 构建可能记录 Provider 类型、请求耗时、HTTP 状态等低频诊断元数据，但不应记录 API Key、Authorization Header 或完整查询正文。

未来如增加新的联网、诊断或发布能力，应同步更新本说明；本文不承诺未来版本永远不增加此类功能。

## 辅助功能与剪贴板

- App 只请求辅助功能权限，用于用户主动触发查询时读取当前选区。
- AX 选区读取失败时，App 可向原前台应用发送一次 Command-C，并在读取后尽量恢复原剪贴板。
- App 不读取剪贴板历史，也不持续监听剪贴板。
- 安全输入状态下不执行剪贴板回退。
- App 不请求屏幕录制、麦克风或系统录音权限。

## Obsidian Markdown

- App 只向用户明确选择或创建的 Markdown 文件写入。
- 目标文件路径保存在本机设置中。
- App 不自动扫描整个 Obsidian Vault，也不上传笔记内容。

## Resource Center

- 当前 production manifest endpoint、payload host allowlist 和信任公钥均为空，因此默认不发起资源目录或 payload 网络请求。
- 未来只有在应用版本内同时注入经过审核的 endpoint、host allowlist 和公钥后，Resource Center 才能获取已签名目录；用户仍需主动选择安装或更新。
- 远程资源必须经过签名、HTTPS/host、大小、SHA-256、许可证、再分发证据和 receipt 验证。
- 手动 MDX 导入不使用网络，不上传词典，也不扫描用户未选择的位置。
- 已安装词典、本地查询和手动导入不依赖 Resource Center 网络可用性。

项目当前不销售用户数据。开放资源准入原则见
[d1-resource-policy.md](d1-resource-policy.md)，实现和部署边界见
[resource-center.md](resource-center.md) 与
[resource-center-deployment.md](resource-center-deployment.md)。
