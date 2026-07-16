# Real MDict validation

Status: phase 2 complete. This document records observed files and measured results; unsupported behavior is not treated as compatible.

## Host

- Machine: MacBook Pro (Mac14,7), Apple M2, 8 GB RAM
- Architecture: arm64 (Apple Silicon)
- macOS: 15.7.7 (24G720)
- Active developer directory: `/Library/Developer/CommandLineTools`
- Swift: 6.1.2, target `arm64-apple-macosx15.0`
- Apple Clang: 17.0.0
- Full Xcode: not installed in `/Applications`; `xcodebuild` is unavailable because only Command Line Tools are active
- Binary choice for phase 1: arm64 only; there is no current requirement for a Universal Binary

## Dictionary inventory (direct inspection)

The inventory and lookup results record a historical, machine-local read-only inspection. Private dictionary paths and compatibility configuration are not part of the source distribution. Original files were not copied, moved, modified, or repackaged by the validation probe.

Totals: 8 MDX, 3 MDD, 9 CSS, 5 JavaScript, 12 loose images, 0 loose audio files, 0 loose font files, and 1 Eudic file.

| Package | Actual files and relationship | Observed status |
|---|---|---|
| Oxford Advanced Learner's 8 bilingual | `牛津高阶英汉双解词典(第8版).mdx` 20 MiB + same-basename MDD 316 MiB + `oalecd8e.css`/`.js` | Matching MDX/MDD pair. CSS, jQuery, dictionary JS, JPEG/PNG, MP3, and `optima.woff2` also exist in MDD. Best validated primary package. |
| Longman Contemporary 5++ | `LDOCE5++ V 1-35.mdx` 195 MiB + same-basename MDD 1.2 GiB + `LM5style.css`, `LM5style_vanilla.css`, `ahd3af.css` | Matching pair. MDD contains MP3, `LM5style_show.css`, jQuery, and `LM5Switch.js`; `LM5style_switch.css` and tested `media/outdated/computer.jpg` are absent. Some common aliases resolve incorrectly with the candidate parser. |
| COCA Frequency 60000 | MDX 2.0 MiB + `COCA Frequency 60000.css`, PNG, `coca.js` | MDX parses. Entry HTML asks for `coca.css`, which does not match the loose CSS filename. No MDD. |
| The Affix Root of Vocabulary | MDX 15 MiB + `Tarov.css` + `Tarov.js` | MDX parses; tested entry references both loose files. |
| Stedman's Medical Dictionary | MDX 3.6 MiB | MDX parses and `heart` returns text. No same-basename MDD. |
| Merriam-Webster's Medical Dictionary, 2015 | MDD 3.9 MiB only | Valid MDD index but no matching MDX in the inspected directory; it is not assumed to belong to Stedman's. |
| 英语常用词疑难用法手册 | MDX 1.4 MiB | MDX parses. Entries reference absent `stylesheet.css`; several exact keys (`a`, `about`, `above`, `accept`) return empty through the candidate parser, while `advice`, `after`, `all`, `allow`, `almost`, and `alone` return content. |
| 牛朗韦柯反查合集 | MDX 128 MiB + `nlwk.css`, `nlwk.js`, `hytycfc.css` | MDX parses and tested `apple`; HTML references `nlwk.css`/`.js`. No MDD. |
| Black's Law Dictionary | MDX 3.1 MiB | MDX parses and tested `contract`. No MDD. |
| The little dict 多功能词频 | 11 PNG, `p.css`, `fy.js`, `config.ini` | No MDX/MDD exists in this folder, so it is not a usable standalone MDict package as inspected. |
| 彭博社专业财经词汇 | one `.eudic` file | Not MDict and outside the requested MDX/MDD core; unsupported in phase 1. |

The loose directory has no audio or font files. Validated audio and the Oxford custom font are stored inside MDD and were read on demand.

## Phase 2 primary-dictionary selection

| Candidate | Exact lookup | Chinese | Examples | Resource correspondence | Parser stability | Suitability for English fiction |
|---|---|---|---|---|---|---|
| Oxford Advanced Learner's 8 bilingual | 10/10 phase-1 common words; 19/20 phase-2 set, with only proper name `Gatsby` absent | Yes | Yes | Same-basename MDX/MDD; referenced CSS, images, MP3, JS and custom font verified in loose files or MDD | Stable MDict v2/UTF-8/zlib path | Best: broad general and literary vocabulary, usage labels, bilingual definitions and examples |
| Longman Contemporary 5++ | 7/10 returned valid full HTML; three aliases selected binary-looking records | Yes | Yes | Same-basename MDX/MDD, but one referenced CSS and one tested image are absent | Not stable enough because of duplicate/alias selection and large problematic records | Strong content, but current parser/resource failures disqualify it for v1 |
| The Affix Root of Vocabulary | Tested `act` successfully | Yes | Contains etymology, construction explanations and examples | MDX with matching loose `Tarov.css`/`.js`; no MDD is present or required by the tested entry | Tested v2 entry is readable, but coverage is specialized rather than general | Useful supplement for word formation, not a dependable primary dictionary for continuous fiction reading |

Selected primary dictionary: **Oxford Advanced Learner's Dictionary 8 bilingual**. It is the only candidate with complete verified resources, stable real queries, Chinese explanations, examples, and suitable general/literary coverage without repairing or renaming original files.

## Security note

External `.js` files are inventory items only. They will not execute in the application. Phase 1 records script references in entry HTML so dictionaries that depend on script behavior can be reported accurately.

## Ten-word real lookup

The Oxford MDX was queried for `apple`, `book`, `computer`, `dictionary`, `example`, `language`, `light`, `run`, `stable`, and `word`.

- 10/10 returned non-empty dictionary HTML.
- All ten previews contained a headword, IPA, part-of-speech/grammar information, and definition text; the HTML also contains example structures.
- Entry sizes ranged from 3,411 bytes (`dictionary`) to 100,975 bytes (`run`).
- Entries contained `entry://` links and resource references.
- `apple`, `computer`, and `light` exposed image references; all ten exposed UK/US audio references.
- Every tested entry contained script tags/references. These are compatibility metadata only and will be stripped/disabled.

The Longman MDX was also queried for the same ten words. Seven returned plausible full HTML. `apple`, `light`, and `stable` returned aliases that the candidate parser followed to binary-looking `ldoce...jpg` records. They are recorded as parser failures, not successful definitions.

## MDD resource reads

Direct MDD queries validated without expanding either archive:

- Oxford: UK and US `apple` MP3 (`fff3` MPEG frame sync), `fruit_comp.jpg` and `apple.jpg` (`ffd8` JPEG), `uk_pron.png` (`89504e470d0a1a0a` PNG), and `optima.woff2` (`wOF2`).
- Longman: UK/US pronunciation MP3s for `book` and `computer`; MDD-contained CSS/JS records were also addressable.
- A small patch was required because upstream `mdict-cpp` rejected valid uncompressed record blocks. The probe now copies only that one record block into memory.

## Known unsupported or incomplete content

- Dictionary JavaScript is deliberately not executed. Features implemented only by those scripts (language toggles, custom interactions, AJAX behavior) will not work unless replaced by safe native link handling.
- `LM5style_switch.css` and the tested Longman `media/outdated/computer.jpg` were not found as loose files or MDD keys.
- The usage handbook's referenced `stylesheet.css` is absent.
- The COCA entry requests `coca.css`, while the loose file is named `COCA Frequency 60000.css`; an explicit safe filename mapping may be needed.
- The candidate parser does not support old MDict v1 LZO blocks or encrypted record blocks. None of the successfully queried packages required them for the tested entries.
- Duplicate/alias selection is not reliable enough in the unmodified parser, demonstrated by three Longman common words and four usage-handbook exact keys.
- HTML sanitization, restricted WebKit navigation, responsive CSS repair, live audio playback, and `entry://` UI navigation are not claimed yet; phase 1 verifies bytes and references only.

## Phase 2 SQLite core validation

The Oxford MDX produced a SQLite index with 109,473 rows (109,467 distinct headword strings). Each row stores the original headword, ASCII-folded value, and global decompressed `record_start`/`record_end`. Metadata stores schema version, source filename/path, source size, mtime with nanoseconds, inode, device, engine version, encoding and entry count.

On later launches the source fingerprint is compared before opening the index read-only. With an unchanged source, the parser uses `initMetadataOnly()`: it reads the MDX header, key-block metadata and record-block metadata but does not decode the complete key list. Record data is decompressed only for the selected offsets.

The 20 real test inputs were:

`Gatsby`, `prodigality`, `supercilious`, `conscientious`, `incredulous`, `juxtaposition`, `melancholy`, `contemptuous`, `obscure`, `extraordinary`, `apple`, `book`, `computer`, `dictionary`, `example`, `language`, `light`, `run`, `stable`, `word`.

Result: **19/20 (95%)**. `Gatsby` is not an Oxford headword; all other required literary words and common control words returned non-empty real records. No fuzzy search, full-text search, name database, or fabricated fallback was used.

Additional normalization checks succeeded:

- `APPLE` → `apple` through case fallback;
- `book,` → `book` through trailing punctuation cleanup;
- `“computer”` → `computer` through surrounding quote cleanup;
- `Extraordinary!` → `extraordinary` through punctuation cleanup plus case fallback.

The record cache is an LRU bounded to **64 records and 8 MiB**, whichever is reached first. In-process repeated lookup of `run` changed from 1.089 ms to 0.033 ms and reported a cache hit.

Phase-2 exclusions remain deliberate: `.eudic`, v1/LZO, encrypted blocks, mismatched packages, incomplete dictionaries, fuzzy/full-text search, lemmatization, UI, WebKit, media playback, `entry://` UI handling, Obsidian and packaging.

## Reproduction

Build with `MDictCore/ValidationCLI/build.sh`, then run `.build/mdict-validate <mdx-or-mdd> <key> ...`. The tool is an arm64 native executable and has no network or background component. Paths are supplied explicitly for a local run and must not be committed; the production App's optional legacy configuration is read from the current user's Application Support `LocalDictionary/LegacyConfig` directory and is never bundled.
