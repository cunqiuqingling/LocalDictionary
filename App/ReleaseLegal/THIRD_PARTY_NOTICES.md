# Third-Party Notices

LocalDictionary 的原创项目代码采用 GPL-3.0-only。本文件汇总构建中实际纳入的第三方源码；这些文件继续适用各自许可证，根目录 GPL 不替代其原始条款。完整许可证文件保留在各组件目录中，本汇总不能代替它们。

## mdict-cpp

- Official upstream: <https://github.com/dictlab/mdict-cpp>
- Fixed commit: `00821615ffbd4fd3d49092a4d26e5c5a6ca10968`
- License: BSD 3-Clause License (BSD-3-Clause)
- Upstream authors recorded in: `ThirdParty/vendor/mdict-cpp/AUTHORS`
- Complete license: `ThirdParty/vendor/mdict-cpp/LICENSE`

The included AUTHORS file names Quan Chen, Hashirama Senju, and glaumar. Local changes are recorded by these patches, applied to the fixed upstream source before vendoring:

- `MDictCore/ValidationCLI/mdict-cpp-phase1.patch`
- `MDictCore/DictionaryCoreCLI/mdict-cpp-phase2.patch`
- `ThirdParty/vendor/mdict-cpp/patches/0003-libtomcrypt-ripemd128-adapter.patch`

The exact included file set and pre-/post-patch hashes are documented in `ThirdParty/README.md` and `ThirdParty/SHA256SUMS`.

## miniz

- Official upstream: <https://github.com/richgel999/miniz>
- Version: 2.1.0
- Fixed commit: `a4264837ae37384b1d7a205a6732db322f0f3769`
- License: MIT License
- Complete license: `ThirdParty/vendor/miniz/LICENSE`

LocalDictionary includes only the miniz compile-time subset required by the reviewed mdict-cpp decompression path. Provenance details and the exact snapshot relationship are documented in `ThirdParty/README.md`.

## LibTomCrypt RIPEMD-128

- Official upstream: <https://github.com/libtom/libtomcrypt>
- Version: v1.18.2
- Fixed commit: `7e7eb695d581782f04b24dc444cbfde86af59853`
- License choice offered by the official license: Public Domain or WTFPL Version 2
- Complete license: `ThirdParty/vendor/libtomcrypt-ripemd128/LICENSE`

LocalDictionary includes only the minimal RIPEMD-128 implementation and compatibility surface required by the MDict encrypted key-info path. The exact upstream source and local compatibility-header derivation are documented in `ThirdParty/README.md` and covered by `ThirdParty/SHA256SUMS`.

## System libraries

SQLite, libxml2, and libarchive are linked as macOS system dynamic libraries; they are not vendored in this repository. Apple system frameworks are likewise not project-vendored dependencies.

## Optional FreeDict English-Chinese resource

The App bundle does not contain this dictionary. If the user chooses it in Resource Center, the
App downloads `eng-zho` version `2025.11.23` directly from FreeDict and converts it locally from the
audited StarDict archive to an internal SQLite query index.

- Source project: <https://freedict.org/>
- Dictionary title: English-中文 FreeDict+WikDict dictionary
- Publisher recorded by the source: Karl Bartel
- Provenance recorded by the source: WikDict; Wiktionary data via DBnary
- License: Creative Commons Attribution-ShareAlike 3.0 Unported (CC-BY-SA-3.0)
- Legal code: <https://creativecommons.org/licenses/by-sa/3.0/legalcode>

Attribution is retained in Resource Center and the installation receipt. The internal derived
database records the source version/hash and transformer version. It is used only for local App
queries and is removed with the resource. The fixed checksums and reproducible field mapping are
documented in `docs/open-resource-freedict.md` in the corresponding source release.

## Optional CC-CEDICT Chinese-English resource

The App bundle does not contain this dictionary. For the active Chinese/English language pair, the
App obtains the current CC-CEDICT editor export from the project host after the user selects it in
Resource Center, then converts bounded GZIP text to an internal SQLite query index.

- Source project: <https://cc-cedict.org/>
- Official download page: <https://cc-cedict.org/editor/editor.php?handler=Download>
- Version: current editor export at the time of the user-requested download
- Attribution: CC-CEDICT contributors; MDBG (publisher); original CEDICT by Paul Andrew Denisowski
- License: Creative Commons Attribution-ShareAlike 4.0 International (CC-BY-SA-4.0)
- Legal code: <https://creativecommons.org/licenses/by-sa/4.0/legalcode>

## Optional Kaikki Chinese Wiktionary English-entry resource

The App bundle does not contain this dictionary. If the user selects it in Resource Center, the App
downloads the fixed English-entry JSONL snapshot from Kaikki.org and converts its reviewed lexical
fields locally to an internal SQLite query index.

- Source and official download page: <https://kaikki.org/zhwiktionary/英語/>
- Snapshot: `2026-08-06T08:56:40Z`
- Attribution: Chinese Wiktionary contributors; Wiktextract/Kaikki.org; Tatu Ylonen
- Content licenses recorded by the source: CC-BY-SA-3.0 AND GFDL-1.3-or-later
- CC legal code: <https://creativecommons.org/licenses/by-sa/3.0/legalcode>
- GFDL text: <https://www.gnu.org/licenses/fdl-1.3.html>

## Optional Princeton WordNet resource

The App bundle does not contain the WordNet database. If the user selects it in Resource Center,
the App downloads the fixed WordNet 3.0 database archive from Princeton's official host, preserves
the applicable notice, and builds a local SQLite index of bounded definitions and semantic links.

- Source project: <https://wordnet.princeton.edu/>
- Official download directory: <https://wordnetcode.princeton.edu/3.0/>
- Version: `3.0`
- Attribution: WordNet 3.0; Princeton University; Copyright 2006 Princeton University
- License: WordNet 3.0 license
- License and commercial-use notice: <https://wordnet.princeton.edu/license-and-commercial-use>

## Optional GNU GCIDE resource

The App bundle does not contain this dictionary. If the user selects it in Resource Center, the App
downloads GCIDE 0.54 from the official GNU host and converts a bounded subset of its dictionary
markup locally to an internal SQLite query index.

- Source project: <https://www.gnu.org/software/gcide/>
- Official download directory: <https://ftp.gnu.org/gnu/gcide/>
- Version: `0.54`
- Attribution: GNU Collaborative International Dictionary of English contributors; GCIDE 0.54
- License: GNU General Public License 3.0 or later (GPL-3.0-or-later)
- License text: <https://www.gnu.org/licenses/gpl-3.0.html>

For the three v0.1 visible starters, Resource Center retains the resource-specific attribution,
source, license identity, version and digests in its reviewed metadata and installation receipt.
CC-CEDICT and Kaikki converter support and notices are retained, but v0.1 offers no new-user
download entry for them. A derived SQLite database is used only for local App queries and is
removed with that resource. Optional dictionary content remains governed by its own license and is
not relicensed by the App's GPL.

Commercial dictionaries and user-imported dictionary data are not software dependencies and are not covered by these notices or by the project's GPL license.

## Distribution reminder

Any future binary distribution must reproduce the applicable third-party copyright notices,
license
terms, and disclaimers in its accompanying materials. The Release build bundles this summary,
the root GPL-3.0-only text, the privacy notice, and source-traceable copies of the three complete
vendored license files under `ReleaseLegal/`. Structural gates require the mdict-cpp and miniz
copies to remain byte-identical. The LibTomCrypt copy differs only by removal of one upstream
trailing space; its words and legal meaning are unchanged, and the gate reproduces that single
normalization from the canonical repository source.
