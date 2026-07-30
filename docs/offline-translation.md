# 离线翻译与中文反向查词

LocalDictionary 使用两套相互独立的本机机制；二者都不是 AI Provider 请求。

## Apple 系统离线翻译

生产引擎是 macOS 15 及以上的 Apple Translation Framework。AppKit 面板内一个真实、可见
的 SwiftUI host view 通过 `translationTask` 持有 `TranslationSession`。Session 不是全局
单例；host 消失后即失效，不会被复用。

每个语言对动态区分：已安装、支持但需要下载、不支持。已安装语言包的普通翻译不会调用
用户配置的 AI Provider。缺少语言包时 App 不会静默下载；只有用户点击“准备离线语言包”
才会调用 `prepareTranslation()`。首次准备可能需要网络，下载界面和资源由 Apple 系统处理，
LocalDictionary 不托管语言包。基础离线翻译可能不准确。

自动化测试只注入确定性 mock engine，不依赖真实语言包、网络或系统下载 UI。

混合或无法可靠识别方向的句子保持独立 `awaitingDirection` 状态，并在对应句子内提供
“译为中文”和“Translate to English / 译为英文”两个原生链接动作。动作 URL 只携带稳定
sentence ID、目标语言和当前 query generation，不包含原句。Native router 会拒绝未知
sentence ID、旧 generation、非法方向、额外参数及超长 URL。切换方向会取消该句旧任务；
晚到结果无法覆盖新方向。翻译成功后只合并对应句，再按最新句子快照重新计算重点词汇，
已存在的 AI 结果保持不变。

需要语言包时，对应句子显示明确的“准备语言包”动作。只有用户点击后，现有可见
SystemTranslationHost 才调用 `prepareTranslation()`；准备完成后只重试该句所选方向。

## 中文反向查词

中文词语和短语使用独立 derived SQLite sidecar，不修改或重打包原始 MDX/MDD，也不扩展
M22 sealed 英文索引。Sidecar 只保存有界、清洗后的释义纯文本、英文 headword、确定性 CJK
term 和身份元数据；不保存原 MDX 绝对路径或无界 HTML。

Sidecar 绑定 dictionary ID、source SHA-256、publication identity、schema version、查询
priority 和用户顺序。它先写临时 SQLite，完成 integrity check 后原子发布。损坏或身份不符
时会被忽略，可安全删除和重建；它不成为 Catalog ready/query authority。

App 启动时不建反向索引。用户从中文查询 fallback 主动开始建立；词条逐条流式清洗和写入，
有 HTML/纯文本上限并支持取消。没有中文内容的词典仍可正常英文查询，只是不贡献反向条目。

排序依次考虑中文精确短语、全部/部分 CJK n-gram、词典优先级、用户顺序和稳定 headword。
结果显示词典来源、命中原因与置信级别，并明确它只是本地候选，不保证唯一正确。

## 长文本与未来扩展

流水线为：

文本规范化 → 逐句语言识别 → 按源语言分批 → 系统离线翻译 → 本地术语/重点词汇（总计最多
15 个）→ 基础结构识别 → 用户主动触发的逐句 AI 深度分析。

翻译始终先显示。不同源语言不会混入一个系统翻译 batch。本地分析使用公开 NaturalLanguage
token、lemma 和 lexical class 加保守规则，只称“基础结构识别”，不是完整语法树或权威依存
分析；低置信度会明确提示。

`ModelPackTranslationEngine` 只预留协议。本次没有独立 NMT 模型、Python、ONNX/CoreML
资源、模型下载器或大型推理框架。未来模型包必须审核许可证、再分发权、来源、版本、大小、
SHA-256、签名、最低 App 版本、语言方向、运行时兼容、内存、延迟、安全安装和安全删除。
