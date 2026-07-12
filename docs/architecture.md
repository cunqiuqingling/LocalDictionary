# Architecture

## Constraints

- One native Swift/AppKit process; no helper server or web server.
- Offline-only; dictionary HTML is untrusted input.
- Dictionary and note paths live in ignored machine-local configuration.
- MDX/MDD files stay in place and are opened read-only.

## Planned components

1. `MDictCore`: a small C/C++17 parser surface bridged to Swift, plus a persistent SQLite headword index.
2. `DictionaryContentPolicy`: rewrites resource and entry links, strips executable content, and prevents network/file navigation.
3. `App`: an `NSStatusItem`, fixed global shortcut, Accessibility selection reader, and a lazily-created `NSPanel` containing a restricted `WKWebView`.
4. `ObsidianWriter`: explicit `.md` selection and duplicate-safe UTF-8 append.

The production parser must keep block metadata and the SQLite index resident, not all headword strings. Compressed record/resource blocks are read and decompressed on demand with a bounded cache.

## Phase 1 parser decision

`dictlab/mdict-cpp` is being used as a compatibility probe because its main parser is BSD-3-Clause, it is native C++17, and it performs record-block reads on demand. It is not accepted unchanged for production: initialization currently materializes all headwords; old LZO blocks and some record modes are incomplete; and its bundled TurboBase64 and miniLZO dependencies are GPL. The probe removes the unused TurboBase64 calls and does not compile or link either GPL component. It uses only the BSD parser subset and MIT-licensed miniz.

The selected production direction is therefore a reviewed, vendored subset of `mdict-cpp` plus miniz, with the following required changes before app integration:

- write headword/record offsets once to SQLite and stop materializing every headword object on later launches;
- preserve duplicate headwords and aliases rather than choosing an arbitrary normalized match;
- support zlib and uncompressed blocks used by the real packages;
- return raw MDD bytes, not hexadecimal or Base64 expansions;
- omit TurboBase64, miniLZO, Hunspell, GoogleTest, and the upstream CLI;
- treat old MDict v1/LZO and encrypted record blocks as unsupported unless a separately reviewed permissive implementation is added.

Alternatives rejected for the application core: GoldenDict/its MDict parser (GPLv3 and Qt-heavy), `js-mdict` (JavaScript plus AGPLv3), Python MDict tools (runtime/service mismatch), and Java parsers (runtime mismatch). The reverse-engineered MDict v2 format description is useful as a test oracle, but not a maintained parsing library.

Sources: [mdict-cpp](https://github.com/dictlab/mdict-cpp), [MDict v2 reverse-engineered format](https://github.com/zhansliu/writemdict/blob/master/fileformat.md), [GoldenDict parser license](https://sources.debian.org/src/goldendict/1.5.0~rc2%2Bgit20200409%2Bds-2/mdictparser.cc/), [miniz](https://github.com/richgel999/miniz).

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

There is no directory watcher, polling loop, background writer, full-text index, fuzzy search, morphology engine, UI or web component.
