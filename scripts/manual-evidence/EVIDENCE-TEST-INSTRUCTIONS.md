# LocalDictionary 污染文本、AI 一致性与动态开放资源定向验收

本产物仅用于人工测试：`MANUAL-TEST-ONLY`、`UNSIGNED`、`NOT-FOR-GITHUB-RELEASE`。它不会安装或覆盖现有 App。本轮只复核下面少量操作，不需要重测完整 Apple 生命周期。

1. 正常退出所有 LocalDictionary，然后双击本目录中的 `Start-Evidence-Test.command`。脚本会从候选目录直接启动 App，并在 Desktop 新建独立 Evidence 目录。
2. 输入 `multiple__organisms__indirectly_`。搜索内容应规范为 `multiple organisms indirectly`；即使本地词典没有整条结果，也应自动显示 English → 简体中文的 Apple 基础翻译。页面还应提示：保持文本不变，连续按三次 Return 可启动 AI 辅助查询。
3. 保持该文本不变，连续按三次 Return。前两次仍是本地/Apple 查询，第三次只触发一次“AI 双语解释”。AI 应把它识别为污染分隔符形成的非标准词组或短语，先给出忠实的中文组合含义，再说明它并非天然固定搭配；不得把下划线当成真实语法，也不得凭空编造因果关系。
4. 输入 `expansive way of`。即使本地词典没有词条，也应自动显示 Apple 中文基础翻译和三次 Return 提示，不得只剩“未找到词条”的空白页。不要为本测试自动下载语言包。
5. 输入一条较长英文污染句，先点击“AI 深度翻译”，记录译文；再点击“逐句 AI 深度分析”。当每句分析都完成后，“AI 深度翻译”区域应与逐句分析中的自然翻译保持一致，不应继续保留一份明显更粗糙、相互冲突的译文。
6. 输入下面的中英混合词表（可直接复制整段）：

   ```text
   rule out vt. 排除
   indigenous |ɪnˈdɪdʒɪnəs| a. 当地的，本地的
   perpetuate |pəˈpɛtʃʊeɪt| vt. 使永久
   larva |ˈlɑːvə| n. 幼虫 pl. larvae
   ```

   离线基础翻译必须同时保留 English 与简体中文两个版本。若 Apple 的中文 operation 仍返回英文，中文版本应安全保留原选择中已经存在的“排除 / 当地的、本地的 / 使永久 / 幼虫”，不得整栏显示“当前不可用”；普通混合句不得因此被原样冒充成译文。
7. 切换 macOS 深色外观，重复一次 AI 双语解释。标题、核心中文释义、英文说明、用法和例句都必须清楚可读，不得出现大面积与背景接近的灰字。
8. 在“词典管理”点击“查找双语开放词典…”。当前母语为简体中文、学习语言为 English 时，等待实时刷新后应至少看到 `FreeDict English → 简体中文` 与 `CC-CEDICT 中文 → English` 两项双语资源。它们来自当前语言组合的官方实时目录匹配，不使用固定版本号或固定 payload SHA。CC-CEDICT 官方导出采用动态传输，安装前大小可以显示“安装时获取”，但不得显示 `Zero KB`；安装完成后应显示实际的非零 MB 大小。分别点击安装；完成后回到词典管理，应看到两本词典为“可用”。FreeDict 应支持 English 正向查询和中文反向索引；CC-CEDICT 应支持中文直接查询。若不想保留，可在测试后分别移除。
9. 从 App 菜单正常退出 LocalDictionary，然后双击 `Collect-Evidence.command`。提供新 Evidence 目录中的 `EVIDENCE-SUMMARY.md`、`evidence.jsonl`、`session-metadata.txt`，并附上失败截图和简短复现步骤。

Evidence 不保存查询正文、AI 回答、私人词典正文、文件路径、API key、Keychain 或 Obsidian 正文。真实 Provider 只会在你明确点击 AI 按钮或第三次 Return 时调用；普通划词、第一次或第二次 Return 不会自动联网。首次运行 unsigned App 如被 macOS 阻止，只使用“系统设置 → 隐私与安全性 → 仍要打开”；不要关闭 Gatekeeper，不要使用 sudo 或 xattr 绕过。
