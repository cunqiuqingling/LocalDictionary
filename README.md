# Local Dictionary for macOS

An offline, minimal macOS menu-bar dictionary backed by a real local MDict index.

## Current status

The current native AppKit application supports manual lookup, Oxford rich-text formatting, Accessibility selection lookup, and a one-shot Command+C fallback when an application does not expose its selection through Accessibility.

## Local configuration

Copy `config/local.example.json` to `config/local.json` and set the local dictionary directory. The real config is ignored by Git. Dictionary and Obsidian files remain in place and are never copied or modified.

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

The Release directory is a temporary build product. `~/Applications/LocalDictionary.app` is the fixed copy intended for daily use and manual testing; rerunning the script replaces it with the latest successful Release build.

## 已知限制

- 微信桌面端内置的微信公众号文章目前可能无法自动获取选区。
- 临时方式为先按 Command+C，再将文字粘贴到词典搜索框查询。
- Chrome、TextEdit、Safari、Obsidian、可复制文字的 PDF 和微信聊天区域已经可以使用全局取词。
- 扫描版 PDF 不支持自动取词，因为目前不包含 OCR。
