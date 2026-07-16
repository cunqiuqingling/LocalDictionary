# Architecture

## Constraints

- One native Swift/AppKit process; no helper server or web server.
- Local dictionary indexing and lookup are on-device; optional, user-triggered AI requests use a user-configured third-party Provider.
- Dictionary HTML is untrusted input and is rendered without WebKit or JavaScript.
- Managed imports copy the selected MDX into the App's Application Support directory; developer-only legacy paths come from optional private Application Support configuration.
- Obsidian output is limited to a Markdown file explicitly selected or created by the user.

## Implemented components

1. `MDictCore`: a small C/C++17 parser surface bridged to Swift, plus a persistent SQLite headword index.
2. Native libxml2 formatters: strip executable and invisible content and map each verified dictionary structure to `NSAttributedString` without WebKit or JavaScript.
3. `App`: an `NSStatusItem`, fixed global shortcut, Accessibility selection reader, and a lightweight `NSPanel` containing an `NSTextView`.
4. `ObsidianWriter`: explicit `.md` selection and duplicate-safe UTF-8 append.

The production parser must keep block metadata and the SQLite index resident, not all headword strings. Compressed record/resource blocks are read and decompressed on demand with a bounded cache.

## Parser and dependency decision

LocalDictionary integrates a reviewed, fixed-commit subset of `dictlab/mdict-cpp` because its parser is BSD-3-Clause, native C++17, and supports record-block reads on demand. The upstream project is not included unchanged: the build omits TurboBase64, miniLZO, Hunspell, GoogleTest, benchmarks, examples, tests and CLI tools. It uses the reviewed mdict-cpp parser subset, the matching MIT-licensed miniz subset, and a minimal official LibTomCrypt RIPEMD-128 implementation for encrypted key-info compatibility.

The recorded patches provide the production behavior required by the SQLite-backed runtime:

- write headword/record offsets once to SQLite and stop materializing every headword object on later launches;
- preserve duplicate headwords and aliases rather than choosing an arbitrary normalized match;
- support zlib and uncompressed blocks used by the real packages;
- return raw MDD bytes, not hexadecimal or Base64 expansions;
- omit TurboBase64, miniLZO, Hunspell, GoogleTest, and the upstream CLI;
- keep unsupported MDict modes outside the production path unless a separately reviewed implementation is added.

Alternatives rejected for the application core: GoldenDict/its MDict parser (GPLv3 and Qt-heavy), `js-mdict` (JavaScript plus AGPLv3), Python MDict tools (runtime/service mismatch), and Java parsers (runtime mismatch). The reverse-engineered MDict v2 format description is useful as a test oracle, but not a maintained parsing library.

Exact versions, included files, patches, hashes and licenses are recorded in `ThirdParty/README.md`, `ThirdParty/SHA256SUMS` and `THIRD_PARTY_NOTICES.md`. A clean build uses tracked `ThirdParty/vendor` files and performs no dependency download.

## Phase 2 implemented core

`SQLiteDictionaryCore` now implements the minimum production data path:

1. compare the MDX stat fingerprint with SQLite metadata;
2. build a temporary SQLite index only when missing, changed, or explicitly rebuilt;
3. preserve duplicate headwords and their global record ranges;
4. reopen SQLite read-only and initialize only MDict block metadata;
5. perform case-sensitive exact lookup, then ASCII case-folded fallback;
6. strip simple surrounding punctuation from a query;
7. decompress only the record block(s) intersecting the indexed byte range;
8. retain returned records in a 64-entry/8 MiB LRU cache.

There is no directory watcher, polling loop, background writer, full-text index, fuzzy search, morphology engine or web component.

## Fixed multi-dictionary runtime

Oxford Advanced Learner's 8 remains the unchanged primary source. Four supplemental sources—21st Century Unabridged English-Chinese, New Oxford English, English-Chinese Medical Dictionary 2003, and The Affix Root of Vocabulary—each use a separate machine-local MDX path, SQLite index, read-only SQLite connection, bounded LRU cache, display name and priority. A failed supplemental source is skipped without interrupting the other dictionaries. Stedman's Medical Dictionary and the unselected script-rendered root dictionary are not configured or opened.

The five developer-local legacy dictionaries and their indexes are not part of the public source distribution. The project can start without private legacy configuration and can operate with user-imported managed dictionaries. Original LocalDictionary project code is GPL-3.0-only; vendored source and dictionary data retain separate licenses and rights.
