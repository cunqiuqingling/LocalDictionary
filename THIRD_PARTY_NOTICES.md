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

SQLite and libxml2 are linked as macOS system dynamic libraries; they are not vendored in this repository. Apple system frameworks are likewise not project-vendored dependencies.

Commercial dictionaries and user-imported dictionary data are not software dependencies and are not covered by these notices or by the project's GPL license.

## Distribution reminder

This repository currently publishes source only. Any future binary distribution must reproduce the applicable third-party copyright notices, license terms, and disclaimers in its accompanying materials. `THIRD_PARTY_NOTICES.md` is a summary and must remain accompanied by the complete vendored license files.
