# LocalDictionary

LocalDictionary 是一个原生 macOS 菜单栏本地词典工具。它支持全局快捷键、手动输入、应用内划词、本地 MDX 导入/索引/查询、用户主动配置的第三方 AI、收藏，以及可选的 Obsidian Markdown 写入。

LocalDictionary is developed and maintained by liuzhentie (刘震铁, aka "cunqiu") with assistance from AI-based development tools. Original project code is provided under GPL-3.0-only. Third-party code and dictionary data remain subject to their respective licenses and rights.

Copyright (C) 2026 liuzhentie (刘震铁, aka "cunqiu")

## 当前公开状态

首次公开阶段只提供源码，暂不提供官方签名或公证的 `.app`。请使用 Xcode 自行构建。正式二进制发布将在签名、公证、Hardened Runtime 和发布流程完善后另行考虑；不建议从非官方第三方来源下载声称属于本项目的预编译 App。

## 主要功能

- 菜单栏与轻量原生 AppKit 查询面板。
- Option-Space 全局查询、手动输入和应用内划词。
- 用户选择的本地 MDX 导入、独立 SQLite 索引与精确查询。
- 可选的第三方 AI 单词解释和句子学习分析。
- 词条收藏，以及写入用户明确选择的 Obsidian Markdown 笔记。

项目不内置商业词典，不提供商业 MDX 下载，也不把 AI 描述为本地离线模型。

## 系统要求

- macOS 15.0 或以上
- Apple Silicon（arm64）
- Xcode 26.3
- Base SDK macOS 26.2

当前不支持 Intel Mac、Windows 或 Linux，也未验证其他 Xcode/SDK 组合。

## 从干净克隆构建

仓库已跟踪构建实际所需的最小第三方源码，不需要额外克隆 `mdict-cpp`，没有 Git submodule，也不需要 Homebrew 第三方依赖或 `local.json`。构建过程不应下载第三方源码。

首次公开仓库建立后，请从代码托管页面复制该项目的官方 Clone URL，使用 `git clone` 克隆到 `LocalDictionary` 目录，然后执行：

```sh
cd LocalDictionary

xcodebuild \
  -project App/LocalDictionary.xcodeproj \
  -scheme LocalDictionary \
  -configuration Debug \
  -derivedDataPath .build/xcode-debug \
  CODE_SIGNING_ALLOWED=NO \
  build

xcodebuild \
  -project App/LocalDictionary.xcodeproj \
  -scheme LocalDictionary \
  -configuration Release \
  -derivedDataPath .build/xcode-release \
  CODE_SIGNING_ALLOWED=NO \
  build
```

检查 Release 架构、最低系统版本和 Bundle：

```sh
APP=.build/xcode-release/Build/Products/Release/LocalDictionary.app
file "$APP/Contents/MacOS/LocalDictionary"
lipo -info "$APP/Contents/MacOS/LocalDictionary"
xcrun vtool -show-build "$APP/Contents/MacOS/LocalDictionary"
./scripts/audit-app-bundle.sh "$APP"
```

Xcode Scheme 的 Release 构建也会运行 Bundle 敏感内容审计。日常本机安装脚本为 `./scripts/install-local-app.sh`，但它不是官方二进制发布流程。

## 本地词典与权利边界

仓库不包含五本开发者本地商业词典、商业 MDX/MDD、索引或词典正文。用户必须自行确认所导入词典的合法来源与使用权限。专用 formatter 只是解析和展示代码，不授予任何商业词典内容权利。

`managedLocal` 导入会把用户明确选择的 MDX 复制到 `~/Library/Application Support/LocalDictionary/Dictionaries/` 下的 App 托管目录。五本开发者本地 `legacyReference` 只通过本机私有兼容配置使用；该 `local.json` 位于 `~/Library/Application Support/LocalDictionary/LegacyConfig/`，不是普通用户构建要求，也不会进入 App Bundle。项目不提供商业词典下载链接。

LocalDictionary 的 GPL-3.0-only 不覆盖用户导入的词典数据。未来 D1 只考虑经过许可证审核的开放资源；准入规则见 [docs/d1-resource-policy.md](docs/d1-resource-policy.md)。

## AI 功能

AI 是可选功能。本地词典查询不需要 AI。用户需要自行配置第三方 Provider；用户主动触发 AI 查询时，当前单词、短语或句子会发送给所选 Provider。

API Key 保存在 macOS Keychain。Provider 名称、URL、模型和开关等非敏感配置保存在本机设置中。项目不内置或分发 API Key，也不保证第三方 Provider 的可用性、价格、政策或隐私行为。详细数据边界见 [docs/privacy.md](docs/privacy.md)。

## 权限与隐私摘要

App 仅请求辅助功能权限，用于用户主动触发查询时读取当前选区。AX 读取失败时会执行一次 Command-C 剪贴板回退，并尽量恢复原剪贴板；App 不持续监听剪贴板。

App 不请求屏幕录制、麦克风或系统录音权限。Obsidian 写入只操作用户明确选择的 Markdown 文件，不扫描整个 Vault。更多说明见 [docs/privacy.md](docs/privacy.md)。

## 第三方依赖

构建使用固定版本的最小依赖子集：

- mdict-cpp：commit `00821615ffbd4fd3d49092a4d26e5c5a6ca10968`，BSD-3-Clause
- miniz：2.1.0 / commit `a4264837ae37384b1d7a205a6732db322f0f3769`，MIT
- LibTomCrypt RIPEMD-128：v1.18.2 / commit `7e7eb695d581782f04b24dc444cbfde86af59853`，Public Domain 或 WTFPL Version 2

来源、文件哈希、patch 和许可证见 [ThirdParty/README.md](ThirdParty/README.md)、[ThirdParty/SHA256SUMS](ThirdParty/SHA256SUMS) 与 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 贡献状态

欢迎 Issue、Bug 报告和功能建议。大型代码贡献请先开 Issue 讨论；项目当前没有 CLA 或 DCO，也不承诺接受所有外部 PR。提交 PR 不表示版权自动转让。

## License

LocalDictionary original project code is licensed under GPL-3.0-only. GPL 不禁止收费分发，但分发者必须履行适用的源码提供义务并保留接收者在 GPL 下的权利。

ThirdParty 文件继续适用各自许可证，词典数据不属于项目 GPL 授权范围。详情见 [LICENSE](LICENSE)、[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) 和 [docs/provenance.md](docs/provenance.md)。

## 已知限制

- 微信桌面端内置的微信公众号文章目前可能无法自动获取选区，可先按 Command-C 再粘贴到搜索框。
- Chrome、TextEdit、Safari、Obsidian、可复制文字的 PDF 和微信聊天区域可使用全局取词。
- 扫描版 PDF 不支持自动取词；当前不包含 OCR。
