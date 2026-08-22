# LocalDictionary Manual Evidence Tool

本工具只为显式启动的人工验收会话记录结构化 JSONL。普通启动 App 时 Evidence 完全关闭。

1. 确认所有 LocalDictionary 已正常退出。
2. 双击 `Start-Evidence-Test.command`。
3. 按候选目录中的 `EVIDENCE-TEST-INSTRUCTIONS.md` 操作。
4. 从 App 菜单正常退出。
5. 双击 `Collect-Evidence.command`。
6. 将新建 Desktop evidence 目录里的 `EVIDENCE-SUMMARY.md` 和 `evidence.jsonl` 提供给 Codex。

工具不读取 Keychain、私人 MDX/MDD、词典正文、Obsidian 正文或 AI 内容。证据只包含事件状态、长度、匿名 SHA-256 identity、公开资源 ID 和 Provider/model 名称。
