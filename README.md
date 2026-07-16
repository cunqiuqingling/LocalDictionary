# Local Dictionary for macOS

An offline, minimal macOS menu-bar dictionary backed by a real local MDict index.

## Current status

The current native AppKit application supports manual lookup, Accessibility selection lookup, a one-shot Command+C fallback, native rich-text formatting, and duplicate-safe multi-source Markdown export. The fixed enabled dictionary order is Oxford Advanced Learner's 8, 21st Century Unabridged English-Chinese, New Oxford English, English-Chinese Medical Dictionary 2003, and The Affix Root of Vocabulary.

The dictionary panel remains visible when it loses focus. AI provider changes invalidate the previous transient request state, and explicit re-query bypasses the current cache. Failed, timed-out, cancelled, or malformed AI responses are not cached; optional word fields such as pronunciation may be absent when a usable definition or name explanation exists. The AI footer supports scoped cache removal, and in-app lookup/translation controls avoid rendered body text or fall back to a separate paragraph action row.

## Local configuration

`config/local.json` is a developer-only, Git-ignored file for the five legacy dictionaries. Copy `config/local.example.json` to that location, set the MDX and independent SQLite index paths, then explicitly install the private configuration:

```sh
./scripts/install-private-local-config.sh
```

The script installs it under the current user's `Library/Application Support/LocalDictionary/LegacyConfig` directory. Debug and Release App Bundles never contain this file. A clean clone and ordinary users do not need it to build or start the app; without it, managed dictionaries, AI settings, the menu bar, and manual input remain available. Dictionary and Obsidian files remain in place and are never copied or modified by this compatibility configuration.

## Validation CLI

`MDictCore/ValidationCLI` is a temporary native C++17 probe for checking real MDX/MDD files, entry HTML, resources, and baseline memory/timing behavior. It has no network access and no background process.

The reviewed phase-1 checkout is intentionally ignored because upstream bundles GPL components that are not part of this project. To reproduce it:

```sh
git clone --depth 1 https://github.com/dictlab/mdict-cpp.git ThirdParty/mdict-cpp
git -C ThirdParty/mdict-cpp apply ../../MDictCore/ValidationCLI/mdict-cpp-phase1.patch
git -C ThirdParty/mdict-cpp apply ../../MDictCore/DictionaryCoreCLI/mdict-cpp-phase2.patch
MDictCore/ValidationCLI/build.sh
```

See `docs/mdict-validation.md` for observed compatibility and `docs/architecture.md` for the planned native architecture.

The phase-2 executable is built with `MDictCore/DictionaryCoreCLI/build.sh`. Its generated SQLite index is machine-local under `.build/` and is ignored by Git.

## Local installation

Run the update script after code changes:

```sh
./scripts/install-local-app.sh
```

The Release directory is a temporary build product. `~/Applications/LocalDictionary.app` is the fixed copy intended for daily use and manual testing; rerunning the script replaces it with the latest successful Release build. Release builds and this installation flow run `scripts/audit-app-bundle.sh` and stop if private configuration, dictionary/index data, runtime catalogs, user notes, or recognizable secret material is found in the App Bundle.

## 已知限制

- 微信桌面端内置的微信公众号文章目前可能无法自动获取选区。
- 临时方式为先按 Command+C，再将文字粘贴到词典搜索框查询。
- Chrome、TextEdit、Safari、Obsidian、可复制文字的 PDF 和微信聊天区域已经可以使用全局取词。
- 扫描版 PDF 不支持自动取词，因为目前不包含 OCR。
