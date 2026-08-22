# 首次 Release 前用户人工验收

本清单目前**没有标记为通过**。只在工程最终验收完成后，对获批源码状态的独立构建执行。
逐项记录 pass/fail、macOS 版本、语言包状态、来源 App、显示器布局；不得在记录中暴露私人
词典正文、路径或密钥。

## 功能清单

- [ ] 1. 英文单词本地查询：五本 preferred 顺序、命中质量和速度不变；测试
  `download`、`culture`、`validation`、`pharmacokinetics`。
- [ ] 2. 中文反向查词：测试文化、苹果、蘋果、下载、验证、提交、肝脏、肾脏；只显示
  精确/高置信词义、来源清楚。
- [ ] 3. “文化”首选 `culture`，不得出现 `diffusion`、`diffusions` 或其他仅在长说明中
  偶然含“文化”的词。
- [ ] 4. v0.1 下载列表不显示 FreeDict、CC-CEDICT 或 Kaikki；历史 FreeDict 僵尸记录可
  明确显示“需要重新安装”并可安全移除。WordNet/GCIDE 只显示并执行英语查询。
- [ ] 5. The Affix Root of Vocabulary 稳定显示“当前词典格式暂不支持中文反向索引”，
  没有红色失败或重复重试入口；普通英文查询不受影响。
- [ ] 6. 英文单词 AI：中文核心释义先于英文定义；测试 `download`、`culture`、
  `validation`、`pharmacokinetics`。
- [ ] 7. 中文单词 AI：推荐英文表达置顶；测试下载、文化、提交、验证、药代动力学。
- [ ] 8. DeepSeek/Gemini 返回安全非空文本即可显示；兼容模式中的粗体、斜体、行内代码、
  列表和段落正常排版，不出现 `**`、反引号或可执行 HTML。
- [ ] 9. 不点击 AI 时 Provider 请求数为零；只在用户主动点击后请求配置的 Provider。
- [ ] 10. 中英语言包状态准确；只有主动点击“准备”才进入 Apple 语言资源流程，首次准备
  可能联网；安装后断网复核系统离线翻译。
- [ ] 11. 英文长句/段落：Apple 结果为中文，句子顺序保持，基础结构提示保守可读。
- [ ] 12. 中文长句/段落：Apple 结果为英文，句子顺序保持，不出现同语言“翻译”。
- [ ] 13. 长文本固定显示离线基础翻译、重点词汇、基础结构分析、AI 深度翻译、逐句 AI
  深度分析五个独立区域；Apple 未完成时不显示词典拼接伪翻译。
- [ ] 14. AI 深度翻译和逐句 AI 自然翻译方向正确：英文→中文、中文→英文；部分字段缺失
  时保留可读结果，不使整项失败。
- [ ] 15. 混合语言分方向处理；每个不确定句分别显示两个方向动作，切换方向时旧结果
  不会闪回；需要语言包时只在对应句主动准备，完成后只重试该句。
- [ ] 16. 单次长文本重点词汇永不超过 15 个。
- [ ] 17. 英文长文本、中文长文本的星标都能点亮；取消收藏恢复空心，重新查询不继承
  其他 query 的星标且不创建明显重复收藏。
- [ ] 18. 中文短词 AI 结果生成前不可收藏 AI；生成后可收藏，且收藏只含原中文 query、
  AI 双语解释和 Provider/model，不含 reverse 候选或 Apple 短词结果。
- [ ] 19. 长文本“收藏时加入 AI 内容”关闭时只保存基础内容，开启时加入 AI 深度翻译和
  逐句分析；AI 后到不会自动取消已收藏状态。
- [ ] 20. AI 部分失败时其他句保留，失败句可重试；单句 AI 深度分析不替换基础结果，
  逐句分析保持句子映射。
- [ ] 21. Safari 划词按钮不覆盖已知选区。
- [ ] 22. Chrome 划词按钮不覆盖已知选区。
- [ ] 23. Preview/可复制 PDF 划词按钮不覆盖已知选区。
- [ ] 24. Xcode 或 TextEdit 划词按钮不覆盖已知选区。
- [ ] 25. 单行选区。
- [ ] 26. 多行大段选区。
- [ ] 27. 四个屏幕边缘、menu bar 与 Dock 附近选区。
- [ ] 28. 多显示器、负坐标与不同 backing scale。
- [ ] 29. 所有已知 bounds 场景均不覆盖；无解或 stale selection 时隐藏。
- [ ] 30. Option-Space。
- [ ] 31. 剪贴板回退并恢复原剪贴板。
- [ ] 32. App 内划词。
- [ ] 33. Provider 切换后 Keychain 不重复循环授权。
- [ ] 34. Resource Center 动态 endpoint/trust 为空；v0.1 Starter Catalog 恰有
  Princeton WordNet、GNU GCIDE 两项，payload allowlist 仅含对应两个已审计官方主机；
  FreeDict、CC-CEDICT 与 Kaikki 不出现在下载列表，且不点击时没有资源网络请求。两项分别执行
  安装、退出重启、查询和删除，均须成功。
- [ ] 35. 明确授权后构建 community unsigned ZIP，文件名为小写 `unsigned` canonical 名。
- [ ] 36. 用 `SHA256SUMS` 和 manifest 复核 SHA-256。
- [ ] 37. 测试机首次阻止时仅使用“系统设置 → 隐私与安全性 → 仍要打开”。
- [ ] 38. 覆盖升级后记录辅助功能权限行为，不预先声称一定保留。
- [ ] 39. 覆盖升级后记录 Keychain 行为。
- [ ] 40. 卸载，并分别记录保留用户数据与用户主动删除数据。

不得关闭 Gatekeeper、运行 `spctl --master-disable`、删除安全属性或全局降低 macOS 安全设置。

## 固定翻译质量文本

每条记录：主旨、反义/严重错误、专有名词、术语、流畅度、基础结构提示帮助程度。约 75% 文本
保留基本主旨只作为人工发布判断，不得写成自动准确率证明。

1. I left the keys beside the blue cup before I went out.
2. Could you send me the revised schedule by Friday afternoon?
3. The train was delayed, but we still arrived before the meeting began.
4. If it rains tomorrow, the outdoor concert will be moved inside.
5. The committee did not approve the proposal.
6. The committee did not necessarily reject every part of the proposal.
7. Not only did the treatment reduce pain, but it also improved sleep quality.
8. Although the results were statistically significant, the effect was small.
9. The device that was installed last week has stopped responding.
10. What the researchers observed could not be explained by temperature alone.
11. The report was reviewed by two independent experts before publication.
12. Having completed the survey, the team began to analyze the responses.
13. The company said revenue had increased while operating costs remained stable.
14. Apple released the update after developers reported a compatibility problem.
15. The central bank may keep interest rates unchanged until inflation slows.
16. Scientists found evidence that the glacier had retreated more rapidly than expected.
17. The model performs well on the test set; however, its production behavior remains uncertain.
18. Correlation does not imply causation.
19. The confidence interval includes zero, so the estimate is not conclusive.
20. Participants who missed more than two visits were excluded from the analysis.
21. The patient was given a lower dose because renal function had declined.
22. This medicine should not be taken with grapefruit juice.
23. Adverse events were generally mild and resolved without additional treatment.
24. The trial was underpowered to detect a clinically meaningful difference.
25. Resistance may emerge when antibiotics are used unnecessarily.
26. 请把会议地址和开始时间再发给我一次。
27. 如果明天下雨，户外活动就改到室内举行。
28. 虽然数据有所改善，但是目前还不能得出确定结论。
29. 这项政策并不意味着所有申请都会被拒绝。
30. 研究人员发现，温度变化可能与观察到的效应有关。
31. 在完成样本清理后，团队开始进行统计分析。
32. 该设备上周安装后一直运行正常，直到今天上午突然停止响应。
33. 公司表示收入有所增长，而运营成本基本保持稳定。
34. 置信区间包含零，因此这一估计尚无定论。
35. 肾功能下降的患者可能需要调整药物剂量。
36. 这种药物不应与葡萄柚汁同时服用。
37. 大多数不良反应较轻，无需额外治疗即可缓解。
38. 由于样本量不足，该试验可能无法检测到具有临床意义的差异。
39. The study enrolled 120 名患者, and follow-up continued for six months.
40. 如果 the hypothesis is correct, these findings could change how the disease is treated.
