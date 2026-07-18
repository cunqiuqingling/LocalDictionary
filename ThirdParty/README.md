# Reviewed third-party source subset

LocalDictionary builds from the files under `ThirdParty/vendor` only. The
developer research checkout at `ThirdParty/mdict-cpp` is ignored and is not a
build dependency. `SHA256SUMS` records every vendored file after the documented
local patches have been applied.

This document records third-party provenance. It does not change the license
of any third-party component. LocalDictionary's GPL-3.0-only license applies
to original project code and does not replace the complete licenses preserved
under `vendor`.

## mdict-cpp

- Official project: <https://github.com/dictlab/mdict-cpp>
- Fixed commit: `00821615ffbd4fd3d49092a4d26e5c5a6ca10968`
- License: BSD-3-Clause, copied unchanged to
  `vendor/mdict-cpp/LICENSE`
- Authors: copied unchanged to `vendor/mdict-cpp/AUTHORS`

Included upstream paths:

```text
LICENSE
AUTHORS
src/mdict.cc
src/binutils.cc
src/adler32.cc
src/encode/api.h
src/encode/base64.h
src/encode/char_decoder.h
src/include/adler32.h
src/include/binutils.h
src/include/mdict.h
src/include/mdict_extern.h
src/include/mdict_simple_key.h
src/include/xmlutils.h
src/include/zlib_wrapper.h
```

The following local patches are applied in order. They are not applied during
the build; the reviewed vendored files already contain their result.

1. `MDictCore/ValidationCLI/mdict-cpp-phase1.patch`
   (`4fa8e7a7e27ffc949309d78106690bec321f1ab17a522f0a83f25af451437094`):
   removes the unused turbobase64 dependency and adds defensive parsing.
2. `MDictCore/DictionaryCoreCLI/mdict-cpp-phase2.patch`
   (`55dbb6036591132825e41d582b09ba4cc1e72e6befc83b759e7818987c8a92ec`):
   adds metadata-only initialization and bounded random record reads used by
   the SQLite-backed runtime.
3. `vendor/mdict-cpp/patches/0003-libtomcrypt-ripemd128-adapter.patch`:
   replaces the old RIPEMD sample call with the project adapter backed by
   LibTomCrypt.
4. D1b-3A-1 metrics probe (manually applied; no standalone patch file):
   adds read-only `const` getter methods to `src/include/mdict.h` so that a
   test-only command-line metrics tool can collect anonymous resource
   statistics.  The getters never run inside the App target.  No object data
   members, object layout, virtual functions, parsing logic, allocation logic
   or error handling are changed.

Files modified relative to the fixed upstream commit have these original and
vendored SHA-256 values:

| Upstream path | Upstream SHA-256 | Vendored SHA-256 |
|---|---|---|
| `src/mdict.cc` | `4051e1d90d87f5a65b2b36f3ac97ae91b338deffbec4fbc20417ecabd8c8a9a7` | `fdf000c601af92f0227df80bbf9b3b240e661e4d0b70bce87835036ffe9d4709` |
| `src/include/mdict.h` | `e83a6a5ab53f14a000da1daf0f88d669303c6b2abddb461f4f0de0dd6ee9d6ff` | `3615de9cf920384e4625f9a6a0e0d134bd67ca8f19e52e003f2b4f39432308c8` |
| `src/encode/base64.h` | `6c0264e1941fcf458b5d7200751cb561025c0e2f616c136e0e07bfdc81f5b4b5` | `19113b27ba310db9fd8cf22988de90f301825e2cc317690614019651a505be51` |

All other mdict-cpp paths listed above are byte-identical to the fixed commit;
their hashes are in `SHA256SUMS`. Excluded content includes turbobase64,
minilzo, Hunspell, googletest, benchmarks, examples, tests, CI files and build
tools.

To update: select and record a new official commit, re-create a clean source
tree, apply the three patches with `git apply --check`, copy only the include
closure above, refresh hashes, then run the vendor, RIPEMD, miniz, bridge and
clean-build smoke tests.

## miniz

- Official project: <https://github.com/richgel999/miniz>
- Version basis: official tag `2.1.0`, commit
  `a4264837ae37384b1d7a205a6732db322f0f3769`
- Exact source snapshot used: `deps/miniz` from the fixed mdict-cpp commit
  `00821615ffbd4fd3d49092a4d26e5c5a6ca10968`
- License: MIT, copied unchanged from that snapshot to `vendor/miniz/LICENSE`

Included paths are `miniz.c`, `miniz.h`, `miniz_common.h`, `miniz_tinfl.c`,
`miniz_tinfl.h`, `miniz_tdef.c` and `miniz_tdef.h`. They are the complete
compile-time closure for the zlib-compatible `uncompress` path used by
mdict-cpp. ZIP APIs, examples, tests and tools are excluded.

The snapshot identifies itself as miniz 2.1.0. Six selected code files are
byte-identical to the official 2.1.0 tag. Its `miniz.h` predates the tag's
additional `MINIZ_USE_UNALIGNED_LOADS_AND_STORES` override guard, so the exact
mdict-cpp snapshot is retained rather than silently mixing sources. The
license text differs from the official tag only by line endings. Every exact
snapshot hash is in `SHA256SUMS`.

To update: first update mdict-cpp, compare its miniz snapshot file-by-file with
an official miniz tag or commit, retain one internally consistent snapshot,
record any difference, refresh hashes and rerun decompression and MDX tests.

## LibTomCrypt RIPEMD-128

- Official project: <https://github.com/libtom/libtomcrypt>
- Stable tag: `v1.18.2`
- Tag commit: `7e7eb695d581782f04b24dc444cbfde86af59853`
- Upstream source path: `src/hashes/rmd128.c`
- License: the upstream `LICENSE` offers public-domain or WTFPL-2.0 terms; the
  exact file is copied to `vendor/libtomcrypt-ripemd128/LICENSE`

The upstream `rmd128.c` is unmodified and has SHA-256
`fc975128fa990bdb53fb5e17115d537551c99d4aa711c016696b5852259f371d`.
The full LibTomCrypt public header graph would introduce declarations for
unrelated ciphers, hashes, PRNGs, public-key algorithms and math backends.
Instead, `vendor/libtomcrypt-ripemd128/include/tomcrypt.h` is a documented
project-local compatibility header containing only the official RIPEMD-128
state, descriptor, byte-order and streaming macro surface needed to compile
that source. Its SHA-256 is
`959b68a326a3eb252c9542dbe22649376c5a305faf17f36214878f6b96cc2a75`.
It was reduced from these official v1.18.2 headers without adding another
hash implementation:

| Upstream path | Upstream SHA-256 |
|---|---|
| `src/headers/tomcrypt.h` | `7e53c3f50b984307fe5cd281c4e3647d9531c928b635b0711f725105e3814576` |
| `src/headers/tomcrypt_cfg.h` | `d08a34a8857a339fd5cef8d9067cb166e34e42e67af7a149e87373d1be281f0e` |
| `src/headers/tomcrypt_hash.h` | `09a4f93300e82e5ecab3047a2a547ba79881e793be569e74563d3da6b291fde6` |
| `src/headers/tomcrypt_macros.h` | `85435fe38c691c171152e6c226221912fcbac7cec18bb7dfb80c8b11fe876259` |

The unabridged header graph is excluded because it declares unrelated
ciphers, hashes, PRNGs, public-key algorithms and math backends.
`MDictCore/RIPEMD128Adapter.c` provides one-shot and streaming
16-byte digest APIs, has no global mutable state, and makes repeated finalize
idempotent.

The standard vectors are taken directly from LibTomCrypt v1.18.2
`rmd128_test()` and are exercised by `Tests/run-ripemd128-miniz-smoke.sh`,
together with segmented updates, multi-block input and interleaved contexts.

To update: pin a new official stable tag and commit, compare `rmd128.c` and the
minimal compatibility surface with the new official headers, refresh hashes,
then rerun all vectors and encrypted-MDX compatibility tests.
