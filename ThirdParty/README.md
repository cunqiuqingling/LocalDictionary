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
5. D1b-3A-2A ResourceLimits and bounded key parsing (manually applied;
   no standalone patch file): adds ResourceLimits model (19 uint64_t + 1
   uint32_t fields) with production defaults and cross-relation validation;
   closed ResourceException error codes; checked-arithmetic helpers for
   uint64_t ↔ size_t/streamoff/streamsize conversions; bounded exact zlib
   decompression (no sourceLen<<3, no <<=2 retry); pre-allocation bounds
   validation for Header and Key-block metadata; per-key-block compressed
   and decompressed size enforcement; runtime checksum and size-mismatch
   rejection replacing Debug-only asserts; integer truncation fixes
   (uint64_t→int, uint64_t→uint32_t, unchecked cumulative addition);
   key_block_info member type widened from unsigned long to uint64_t;
   offset members widened from uint32_t to uint64_t.
   This patch changes Mdict object layout (limits_ and actual_file_size_
   members added).  All in-repository callers are rebuilt together;
   no external binary ABI is promised.  Existing source callers continue
   through default constructors (which use production defaults).

6. D1b-3A-2A-R1 Key-path memory safety (manually applied; no standalone
   patch file): fixes type-0 key block use-after-free by owning all
   decompressed data in std::vector<uint8_t>; enforces exact
   payload/decomp/Adler-32 validation for uncompressed type-0 blocks;
   rewrites split_key_block with complete boundary validation (null
   pointer, empty buffer, number_width bounds, UTF-8/UTF-16 delimiter
   checks, maximumSingleKeyBytes enforcement, stale key_end_idx sentinel,
   key_start_idx advance guard, checked subtraction, RAII temporary
   buffers); fixes key-block-info prefix check ordering (buffer/null
   validation before memory access); adds pre-allocation EOF checks for
   both full key-block and per-block reads; converts Header buffer,
   Key-block header buffer, Key-block-info buffer, full key-block
   compressed buffer, single key-block compressed buffer, and
   decompression output to RAII (std::vector<uint8_t> / std::string);
   fixes bounded zlib error model (malformedCompressedData instead of
   checksumMismatch, std::bad_alloc → allocationFailed, sourceLen==0
   rejection); adds external Adler-32 checksum for key-block-info
   (version >= 2); removes the spurious validate() cross-relation
   maximumTotalRecordBlockDecompressedBytes >=
   maximumTotalRecordBlockCompressedBytes; activates
   maximumSingleKeyBytes in split_key_block.

7. D1b-3A-2A-R2 Key ownership and actual-entry bounds (manually applied; no
   standalone patch file): retains each block's declared entry count and
   verifies it against the number of keys actually parsed in both full and
   by-block query paths; bounds the checked global actual-entry accumulator;
   keeps temporary key and key-block-info objects under `std::unique_ptr`
   ownership until validation and destination reservation are complete;
   requires the complete four-byte Key-block compression prefix to be exactly
   type 0, 1, or 2; rejects an empty payload; corrects the UTF-16 Header
   encoding branch; and adds test-only allocation, decompression and live-item
   observers that are absent unless `MDICT_RESOURCE_TEST_OBSERVER` is defined.
   Record-block resource enforcement remains D1b-3A-2B. Directory-descriptor
   `openat`/`renameat` hardening remains D1b-3B; reading size from the opened
   stream avoids a separate stat-size lookup but is not described as complete
   path/open TOCTOU hardening.
8. D1b-3A-2A-R2.1 Resource regression coverage (manually applied; no
   standalone patch file): restores synthetic parser-path coverage for Header
   checksum and EOF boundaries, Key-info prefix and external Adler checks,
   Key-info/per-block limits, checked offset overflow, and version-1
   four-byte Header fields.  The extra Key-info input-allocation counter and
   the Header-only fixture entry point exist only when
   `MDICT_RESOURCE_TEST_OBSERVER` is defined.  In production builds,
   `key_list_item` has no explicit test destructor, the observer declarations
   and state do not exist, and no observer symbol or string is emitted.
9. D1b-3A-2A-R3 Header checksum byte order (manually applied; no standalone
   patch file): decodes the MDX Header Adler-32 field as a little-endian
   uint32. Header length remains big-endian, and all subsequent Key/Record
   checksum fields retain their existing format-specific byte order.
10. D1b-3A-2B Record metadata and block decoding (manually applied; no
    standalone patch file): bounds Record summary count and metadata before
    allocation; requires the exact `count × 2 × numberWidth` pair-table
    shape; uses checked offsets and atomic RAII metadata commit; enforces
    single and cumulative Record block limits; and routes the Record block
    paths through canonical-prefix, exact-size, bounded-zlib decoding with
    big-endian Adler-32 verification. Test observers remain entirely behind
    `MDICT_RESOURCE_TEST_OBSERVER` and have no production state or symbols.
    Record range reads validate start/end against the checked decompressed
    stream size before `reserve`, enforce the requested-range cap, and check
    every cross-block append against the returned-byte cap before mutation.
    The legacy full-record implementation below the early return in
    `decode_record_block()` is currently unreachable and must not be restored
    as a production path; a later isolated cleanup may remove that dead code.

Files modified relative to the fixed upstream commit have these original and
vendored SHA-256 values:

| Upstream path | Upstream SHA-256 | Vendored SHA-256 |
|---|---|---|
| `src/mdict.cc` | `4051e1d90d87f5a65b2b36f3ac97ae91b338deffbec4fbc20417ecabd8c8a9a7` | `ad7bd8f1692621d7dc886bda79d719ba4dec6f3e6b601342bb1f247225b1e764` |
| `src/include/mdict.h` | `e83a6a5ab53f14a000da1daf0f88d669303c6b2abddb461f4f0de0dd6ee9d6ff` | `a7ea81a90c71953f703ef9755fd11b60585ba17462dcec4ec76b884df2e8f780` |
| `src/include/zlib_wrapper.h` | `29d187709287366541e387cdea35cbe39c8eea6ad32cd92746276ca0c05c0b28` | `0e1e75b8ee84014cd731b033aa755991cc3d055db6f39595bcb91e18d0c5a356` |
| `src/encode/base64.h` | `6c0264e1941fcf458b5d7200751cb561025c0e2f616c136e0e07bfdc81f5b4b5` | `19113b27ba310db9fd8cf22988de90f301825e2cc317690614019651a505be51` |

New files added by D1b-3A-2A:

| Path | Vendored SHA-256 |
|---|---|
| `src/include/resource_limits.h` | `6366aa50f76de403791763173368572c19b4dd3db44bd43d56d58db1ddbc11f5` |
| `src/include/checked_arithmetic.h` | `c6b8b19e05b522209d26ce40194ac1df4d82da3ea578eb5e420bfca18a7b7881` |
| `src/include/bounded_zlib.h` | `1ca20f9bc6b258ab21b10ecb93c3db422943cc5ff5874619f508110d643f41c6` |
| `src/include/resource_test_observer.h` | `4fa72f4fb8da7a1391e7a1faf78cafc52a600d8ab517a8c9605fc527cc3ea0c3` |

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
