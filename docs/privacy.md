# Privacy

本文描述当前源码版本的实际数据边界。LocalDictionary 没有项目自有服务器；本地词典在设备上运行，可选 AI 功能会连接用户配置的第三方服务。

## 本地词典

- 本地词典查询和 SQLite 索引在设备上执行。
- `managedLocal` 导入会把用户明确选择的 MDX 复制到本机 Application Support 的 App 托管目录；原始导入文件不会因托管副本的建立或移除而被修改。
- App 不自动上传词典文件或词典正文。
- 中文反向查词索引只在用户点击建立/重建时，从已校验且已启用的本地词典逐条流式派生；
  索引仅保留有界的 headword、纯文本释义摘要、来源身份和检索词元，不保存 MDX 路径或 HTML。
- 开发者本机的 legacy 私有配置只从 `~/Library/Application Support/LocalDictionary/LegacyConfig/local.json` 读取，不进入 App Bundle。
- 仓库和 App Bundle 均不包含商业词典。

## AI 请求

只有用户明确点击某个 AI 功能时，LocalDictionary 才会向所选 Provider 发送请求。
普通单词查询、中文反向查词、基础离线翻译、重点词汇提取和基础句法提示都不会自动调用
AI。请求可能包含：

- 当前单词、短语或句子；
- 生成结构化响应所需的系统提示；
- 所选模型和响应格式参数。

LocalDictionary 不主动向 AI Provider 发送整本词典内容、本地词典路径、Obsidian 笔记正文、剪贴板历史、页面中未选中的其他内容或其他查询历史。用户的 API Key 直接用于访问其所选 Provider，不会发送给项目作者。

第三方 Provider 可能有自己的日志、保留、训练、计费和隐私政策；LocalDictionary 无法控制或保证这些行为。使用前请查看对应 Provider 的条款。

## Apple 系统离线翻译

- 基础中英翻译使用 macOS Translation framework，由 Apple 系统管理模型与执行环境；
  LocalDictionary 不托管语言包，也不把它描述为项目自有 AI 服务。
- 语言包缺失时，只有用户点击“准备离线语言包”后才会进入系统准备流程；App 启动、普通查词
  和长文本分析都不会静默触发下载。
- 语言包安装后，翻译请求由系统 framework 在本机处理。系统组件自身的行为受 Apple 的系统
  软件条款与隐私政策约束。

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

- App 首次启动会说明可选的辅助功能权限；该权限只用于用户主动触发查询时读取当前选区，未授权仍可手动查词。
- AX 选区读取失败时，App 可向原前台应用发送一次 Command-C，并在读取后尽量恢复原剪贴板。
- App 不读取剪贴板历史，也不持续监听剪贴板。
- 安全输入状态下不执行剪贴板回退。
- App 不请求屏幕录制、麦克风或系统录音权限。
- 划词按钮位置只使用辅助功能 API 返回的选区几何与屏幕 `visibleFrame`；不截屏、不读取
  屏幕像素。无法取得新鲜、可靠且不重叠的位置时，按钮隐藏。
- 用户通过全局快捷键打开选区结果后，仅在该结果面板可见期间短暂复核同一来源应用的
  选区文本和几何；文本变化、选区消失或来源应用切换时立即隐藏，几何变化时重新避让。
  复核数据不写入磁盘，也不用于后台持续监控。

## Obsidian Markdown

- App 只向用户明确选择或创建的 Markdown 文件写入。
- 目标文件路径保存在本机设置中。
- App 不自动扫描整个 Obsidian Vault，也不上传笔记内容。

## Resource Center

- App 的签名 manifest endpoint 与信任公钥仍为空。打开、刷新 Resource Center 或切换
  母语/学习语言时，App 会访问 FreeDict 官方目录，实时筛选当前语言对可用的双语词典；
  中英组合还会显示 CC-CEDICT 官方当前导出。WordNet 与 GCIDE 只作为 English 相关组合的
  英英补充。
- 浏览列表只下载有限的目录 metadata，不下载词典正文。只有用户点击“下载并安装”后，App
  才连接相应的精确官方 HTTPS 主机并运行 typed converter。FreeDict 校验官方目录给出的
  SHA-512；官方当前导出没有上游摘要时，App 在下载后计算 SHA-256，并把实际字节数与摘要
  写入本机安装 receipt，而不是把易变大小或哈希写死在 App 中。
- 每项资源都必须具有可显示的许可证 metadata、明确语言方向、受限下载与 typed source
  format；转换结果仅在本机发布为内部 SQLite。
- App Bundle 不包含 Starter 词典正文，App 不重新托管正文，也不把原始资源或转换结果上传
  到项目方或 AI Provider。
- 手动 MDX 导入不使用网络，不上传词典，也不扫描用户未选择的位置。
- 已安装词典、本地查询和手动导入不依赖 Resource Center 网络可用性。

项目当前不销售用户数据。开放资源准入原则见
[d1-resource-policy.md](d1-resource-policy.md)，实现和部署边界见
[resource-center.md](resource-center.md) 与
[resource-center-deployment.md](resource-center-deployment.md)。
