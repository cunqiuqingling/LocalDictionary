# Tests

## D1b-3A-2A-R2 bounded Key parsing

`run-d1b3a2a-resource-limits-smoke.sh` builds a runtime-only synthetic MDX
suite in Debug (ASan/UBSan and warnings-as-errors) and Release
(`-O2 -DNDEBUG` and warnings-as-errors). It exercises actual per-block and
global entry counts, RAII rollback, canonical four-byte compression prefixes,
type-0/type-2 checksums, cumulative metadata arithmetic, UTF-16 delimiters,
all 20 ResourceLimits defaults, all seven checked-arithmetic helpers, and
test-only allocation/live-item observers. R2.1 additionally exercises real
Header checksum/EOF/limit paths, short Key-info prefixes and external Adler,
Key-info and per-block limit boundaries, EOF/checked-offset overflow paths,
and the version-1 four-byte Header fields. The observer macro also exposes a
test-only Header entry point and Key-info input-allocation count; production
builds declare neither hook nor lifecycle observer. It uses no private
dictionary, network, Keychain, local configuration, or Application Support
data.

R2.1 explicitly authorizes the test-only Key-info allocation observer
declarations in `resource_test_observer.h`; they are compiled only when
`MDICT_RESOURCE_TEST_OBSERVER` is defined. The final smoke count is the total
runtime assertions, including fixture/setup assertions; it is not a count of
independent security behaviours. Independent behaviour groups are Header
integrity and limits, Key-info prefix and Adler validation, Key-info and
per-block resource limits, EOF and checked-offset overflow, version-1
four-byte Header fields, ownership rollback, UTF-16 boundaries, bounded zlib,
and production-limit compatibility. The test-only Header entry point calls the
real Header parser, duplicates a small amount of initialization preflight, and
must remain synchronized with the production initialization path.

`run-d1b3a2b-record-resource-limits-smoke.sh` builds a synthetic Record
metadata and bounded-block decoder suite in Debug and Release. Its reported
count is total runtime assertions, including fixture/setup assertions; it
does not read private dictionaries, `local.json`, or Application Support. It
exercises independent parser-path groups for Record summary limit-first
precedence, exact/+1 info/count/single/cumulative limits, checked cumulative
overflow, short and canonical compression prefixes, type-0 and zlib exact
size/Adler/EOF validation, metadata rollback and repeat initialization,
test-only allocation-failure mapping, and single/two/three-block range and
returned-byte limits. The test-only observer additionally proves range-limit
rejection happens before reserve and returned-byte rejection happens before
the next append. These groups are behaviour coverage, not a count derived
from the total runtime assertions.

Directory-descriptor
`openat`/`renameat` hardening remains a D1b-3B task.

Phase 2 was exercised against the selected real Oxford MDX with the documented 20-word set. Additional checks cover ASCII case fallback, English and curly-quote cleanup, trailing punctuation cleanup, read-only index reuse, SQLite integrity, and an in-process cache hit.

`run-multidictionary-smoke.sh` reads the ignored machine-local configuration and tests all five fixed dictionaries through the production SQLite core and native formatters. It writes only ignored fixtures and temporary Markdown notes below `.build/`; no dictionary or user note is copied or modified. The smoke test also verifies multi-source Markdown sections, duplicate prevention, and isolation of a missing dictionary path.

`run-dictionary-catalog-smoke.sh` tests the versioned catalog model, atomic primary/backup persistence, corruption recovery, relative-path validation, optional legacy configuration loading, stable priority sorting, and idempotent five-dictionary legacy adaptation. It uses only temporary placeholder files and a minimal temporary SQLite metadata table; it never opens a real MDX or invokes the production index builder.

Stage A stores `catalog-v1.json` and `catalog-v1.backup.json` under the app's user Application Support `LocalDictionary/Catalog` directory. The app starts with an empty catalog when the developer-only external `LegacyConfig/local.json` is absent; when it is present, the existing five dictionaries remain on the unchanged legacy query dispatcher and are represented only by path-free `legacyReference` catalog records. The private file is never copied into Debug or Release App Bundles.

`run-local-configuration-isolation-smoke.sh` uses an isolated HOME to verify the single production lookup location, safe missing/corrupt behavior, explicit test-only URL injection, five path-free legacy descriptors, idempotent adaptation, and the absence of legacy index writes. `run-app-bundle-audit-smoke.sh` verifies that clean bundles pass while private configuration, MDX/MDD, SQLite/Catalog/PendingDeletion data, user paths, bearer headers, and synthetic secret fields fail without disclosing matched values or modifying the bundle. It also exercises the developer-only private-config installer in an isolated HOME.

`run-app-icon-persistence-smoke.sh` verifies that the tracked ten-slot macOS `AppIcon.appiconset` is the only icon source, that Debug and Release both select `AppIcon`, and that `Assets.xcassets` belongs to the target resource phase. The Release Bundle audit additionally requires generated `Assets.car`, `AppIcon.icns`, and matching `CFBundleIconFile`/`CFBundleIconName` values, while rejecting Finder custom-icon files. The installer reuses the same Bundle audit before publishing to `~/Applications`.

`run-dictionary-import-smoke.sh` exercises the macOS-only B1 managed import boundary with generated header-only MDX fixtures and small placeholder MDD files. It covers strict MDD basename pairing, preview metadata, cancellation, disk-space rejection, disappearing sources, SHA-256 duplicate detection, staging rollback, relative Catalog paths, and the absence of index artifacts. B1 only copies files and creates `pendingIndex` records; imported dictionaries are not connected to production queries.

`run-dictionary-indexing-smoke.sh` exercises the B2 managed-index state machine with generated source bytes and an injected SQLite builder. It covers success, failure and retry, cooperative cancellation, one-at-a-time execution, source fingerprint and disk-space rejection, integrity validation, interrupted-build recovery, relative Catalog paths, and protection of an existing final index. B2 produces verified independent indexes only after explicit user action; ready managed dictionaries are still excluded from production queries.

`run-managed-dictionary-query-smoke.sh` exercises the B3 preferred-to-managed fallback policy, canonical and legacy generic formatter identifiers, B1 root-level and future `source/` managed MDX layouts, path/symlink escape rejection, stable Catalog ordering, state filtering, isolated failures, source SHA-256 and read-only SQLite validation, and safe managed dictionary snapshots for Markdown. It uses generated placeholder bytes, a temporary SQLite metadata table, and a mock managed runtime; it never opens a commercial MDX or accesses the network.

`run-generic-mdict-formatter-security-smoke.sh` validates the B3 libxml2 safety boundary with synthetic HTML. It verifies basic headings, paragraphs, lists, emphasis and code while discarding scripts, embedded content, hidden nodes and URL-bearing attributes, and enforcing raw-byte and DOM-depth limits.

`run-dictionary-ordering-removal-smoke.sh` exercises the B4 same-level ordering and managed removal boundaries. It covers persistent preferred/normal/fallback ordering, cross-level rejection, save rollback, stable default restoration, legacy adapter order preservation, managed-only two-phase removal, Catalog rollback, interrupted-removal recovery, deferred cleanup, runtime release, and absolute/traversal/other-UUID/symlink path rejection. It uses generated placeholder files in a temporary directory and never opens a commercial dictionary, accesses the network, or modifies an Obsidian note.

`run-dictionary-manager-ui-state-smoke.sh` covers the C1 dictionary-manager presentation model and a lightweight in-process AppKit layout pass. It verifies user-facing source/query/status wording, cooperative cancellation and removal states, index-action titles and disabled reasons, table-width assumptions, empty/populated manager layouts, import-preview layout, and the absence of internal path/SQLite/Catalog details in manager error messages. It does not launch the product, access a dictionary, or use the network.

`run-ripemd128-miniz-smoke.sh` compiles the project RIPEMD-128 adapter with the fixed LibTomCrypt source and exercises the official standard vectors, segmented and multi-block updates, independent contexts, idempotent finalization, and sanitizer checks. It also validates the fixed miniz subset with synthetic round-trip and truncated-input decompression, plus the mdict-cpp encrypted key-info boundary against an independent synthetic reference; no dictionary or network is used.

`run-third-party-vendor-smoke.sh` verifies the exact reviewed vendor file set, recorded SHA-256 values, license files, Git visibility, forbidden dependency exclusions, and the absence of build/test references to the ignored research checkout, old RIPEMD sample, miniz ZIP code, or turbobase64.

`run-open-source-compliance-smoke.sh` performs an offline source-release check. It verifies the exact official GPLv3 root license text, GPL-3.0-only scope statements, third-party notices and fixed provenance, vendored licenses and hashes, privacy/security documentation, D1 policy placeholders, absence of private paths and obvious secret values in public documentation, and consistency between clean-build, AI-network, and private `local.json` statements. It does not access the network, user Application Support, Keychain, dictionaries, or build products.

`run-public-ci-smoke.sh` is the public GitHub Actions entry point. It runs only synthetic or source-compliance tests under an isolated HOME, disables the real Keychain smoke, uses MockURLProtocol for AI transport, and includes `run-public-obsidian-note-store-smoke.sh` for temporary Markdown files. It intentionally excludes `run-multidictionary-smoke.sh` and the private Oxford stage in `run-obsidian-smoke.sh`, because those require the ignored developer `local.json`, commercial dictionaries, and private indexes.

`run-resource-manifest-security-smoke.sh` covers the offline D1b-1 trust foundation with runtime-generated TEST-ONLY Ed25519 keys and synthetic JSON. It verifies the binary detached-signature envelope, raw-byte signatures, strict duplicate-key/unknown-field JSON parsing, closed Manifest v1 semantics, URL and filename limits, rollback protection, atomic state persistence and permissions, empty production trust, and the Catalog/external-reference boundary. It uses only a temporary rollback directory and does not access the network, Keychain, real Application Support, or dictionary data.

`run-resource-manifest-network-smoke.sh` covers the offline D1b-2A HTTPS transport with an injected `URLProtocol`. It verifies exact-host URL and redirect policy, bounded chunked signature/Manifest delivery, status/content rules, cancellation, one-refresh-at-a-time behavior, cookie/cache isolation, raw-byte verifier handoff, and disabled production endpoint/trust defaults. It uses only synthetic `example.test` URLs and runtime-generated TEST-ONLY Ed25519 keys; it performs no DNS or network access and writes no resource, Catalog, or rollback state.

`run-resource-payload-download-smoke.sh` covers the offline D1b-2B single-MDX payload boundary. It verifies signed/App exact-host intersection, UInt64 size and disk-capacity limits, chunk-by-chunk POSIX writes, incremental SHA-256, HTTP and redirect policy, cancellation and single-flight behavior, `0700`/`0600` staging permissions, failure cleanup, and fsync/atomic publication from `.partial-*` to `verified-*`. It uses only synthetic bytes, temporary directories, and an injected `URLProtocol`; production payload hosts remain empty and no Catalog, index, query, AppDelegate, UI, real resource, or Keychain is involved.

`run-resource-payload-staging-security-smoke.sh` covers D1b-3B-1's directory-fd staging boundary in Debug (Address/Undefined Behavior Sanitizers) and Release. It uses only synthetic payloads and isolated temporary roots to verify single-component rejection, root and payload type/`0600` permission checks, fd-bound byte/SHA accounting, partial-file substitution, symlink and hardlink rejection, operation-directory substitution, static and real `RENAME_EXCL` publication races, durability-boundary cleanup, inode preservation, and non-recursive cleanup. Its output is total runtime assertions, including fixture/setup assertions; that count is not a count of independent security behaviours. The fixtures intentionally cover genuine POSIX no-replace races, injected fsync and cross-device failures, and known-component cleanup; true short-write/EINTR, fd-close, owner-mismatch, nested-symlink, and fd-bound-capacity fixtures remain deferred. Production builds contain no test fixture or fault-injection state. Orphan recovery, Catalog/open-resource installation, indexing, and production payload hosts remain outside this stage.

## D1b-3A-2B-M1 anonymous Record compatibility metrics

`run-mdict-resource-metrics-probe-smoke.sh` builds a synthetic-only Debug
(ASan/UBSan, warnings-as-errors) and Release (`-O2 -DNDEBUG`,
warnings-as-errors) probe. It accepts only explicitly supplied repeated
`--mdx <path>` and `--sqlite <path>` inputs; it never scans directories,
`local.json`, Application Support, or any default dictionary location. The
probe opens supplied SQLite files read-only and does not alter its inputs or
create journal/WAL/SHM sidecars.

Its JSON is one anonymous global aggregate, containing only numeric metadata
and fixed field names. It never writes input paths, filenames, dictionary IDs,
headwords, entry text, record bytes, hashes, UUIDs, or row samples. Existing
MDX total fields retain their maximum-single-input semantics; the new
`maximumRecordRangeBytes` is the maximum validated
`entries.record_end - entries.record_start` range across all explicitly
supplied SQLite inputs. Invalid SQLite types, negative offsets, decreasing
ranges, overflow, and missing schema fail without emitting partial JSON.

D1b-3A-2B-M1.1 identifies UTF-16 MDict Header versions and encryption modes
without emitting Header text. It supports test-tool-only, read-only Record
metadata summaries for engine 1.x (four-byte numbers) and 2.x (eight-byte
numbers), using the vendored format's Record summary and compressed/
decompressed pair table. It validates pair-table shape, checked offsets,
checked accumulators, declared compressed totals, and EOF before it reads no
more than metadata. It never reads Key text, entry text, or Record payload.
Unknown future major versions remain successful anonymous identifications with
`identifiedButUnsupportedVersion`; encrypted inputs report
`identifiedButUnsupportedEncryption` because detailed Key metadata is not
claimed without decrypting it. `metricsSupportStatus` is a fixed anonymous
enum: `supported`, `identifiedButUnsupportedVersion`,
`identifiedButUnsupportedEncryption`, `mixedVersions`, or `noMDXInput`.

D1b-3A-2B-M1.2 keeps checksum verification strict and adds an optional
`--diagnose-checksum` failure protocol for owner-run Release measurements. On
a checksum failure it writes only fixed anonymous JSON to stdout and returns
nonzero; it never emits a partial metrics file. `checksumFailureStage` is one
of `none`, `header`, `keyInfo`, `keyBlock`, or `recordBlock`. Each stage status
is one of `valid`, `mismatch`, `notReached`, `notChecked`, or `notApplicable`.
`headerChecksumEncodingMatch` is `canonicalLittleEndian`,
`byteReversedBigEndian`, `neither`, or `notChecked`. Header Adler-32 is stored
as a little-endian uint32; Header length stays big-endian, while Key-info,
Key-block, and Record-block Adler fields remain big-endian. The
`byteReversedBigEndian` value is only an anonymous negative observation: it
remains a strict failure and is not a supported compatibility format.
Header mismatch stops before version, encryption, Key, or Record parsing;
`notReached` means a preceding failure prevented the stage, whereas
`notChecked` means the probe intentionally does not read that payload.

The probe never writes expected/actual checksum values, raw Header bytes,
Header text, paths, filenames, or input mappings. The smoke uses tiny fixed
golden UTF-16LE byte arrays with independently precomputed, hardcoded Header
checksum constants, including canonical, byte-reversed, mismatch, exact-EOF,
missing-byte, and one-byte-coverage-boundary cases. Runtime fixture creation
does not call an Adler helper to construct those expected constants. Manual
diagnosis remains outside Codex and must use placeholders only:

```sh
Tests/run-mdict-resource-metrics-probe.sh --release --diagnose-checksum \
  --mdx /path/to/owner-supplied.mdx \
  --output /path/to/anonymous-checksum-output.json
```

Do not commit a private MDX, SQLite database, local path, or either output
file. The total runtime assertion count includes fixture/setup assertions; it
is not a count of independent security behaviours.

Codex and CI run only the generated synthetic fixtures. A dictionary owner who
chooses to run the Release-only tool manually must provide every input and may
retain only the resulting anonymous JSON outside the repository:

```sh
Tests/run-mdict-resource-metrics-probe.sh --release \
  --mdx /path/to/owner-supplied.mdx \
  --sqlite /path/to/owner-supplied.sqlite \
  --output /path/to/anonymous-record-metrics.json
```

The placeholders above are documentation only: do not add real private paths,
dictionary files, indexes, or produced metrics JSON to Git.

The repository is currently source-only and targets macOS 15.0+ on arm64. A clean clone builds from tracked `ThirdParty/vendor` files without a submodule, a separate mdict-cpp clone, Homebrew dependencies, or private `local.json`. The only runtime permission required for selection lookup is Accessibility; the App does not request screen recording, microphone, or system audio recording permission.

## C1 manual acceptance checklist

## D1b-3B-2A synthetic installation smoke

`Tests/run-open-resource-installation-smoke.sh` constructs only a synthetic signed-payload
identity, publishes `payload.mdx` and the immutable `resource-installation.json` receipt into an
isolated temporary root, then verifies the Catalog v2 `openResource` descriptor is fallback /
pending-index. It never reads Application Support, private dictionaries, local configuration, or
network resources. Catalog v1 files remain untouched and are migration input only; v2 becomes
authoritative only after its first successful durable save.

D1b-3B-2A-R1 also covers Catalog provenance and final-publication races with synthetic files:
only a genuinely missing Catalog may begin from an empty value; corrupt or unsupported Catalogs
are read-only and cannot be rewritten by import, index, ordering, removal, startup adaptation, or
open-resource installation. A Catalog mutation takes a short lock, reloads the latest durable
Catalog, changes only its target descriptor, and never encloses download, copying, indexing, or
query work. The backup is the previous valid v2 primary, not the in-progress new primary.

D1b-3B-2A-R2 decodes both primary/backup peers of the authoritative generation before selecting a
writable Catalog. An unsupported peer blocks a valid peer in the same generation, while a corrupt
peer still permits recovery from its valid counterpart. Existing valid v2 data remains
authoritative over stale v1 files. Synthetic mixed-version tests verify exact write rejection plus
unchanged file contents and inodes; the other deferred 2A test-matrix improvements remain outside
R2.

The installation smoke uses real POSIX files and `renameatx_np(RENAME_EXCL)` to verify that the
sidecar is bounded-read and matched to its immutable identity before publication, that the source
name is rebound to the verified directory fd immediately before rename, and that the final
payload/sidecar are rechecked before a Catalog commit. Test-only rename interlocks are compiled
only by the smoke runner; they are not part of the App target. Final objects that fail a
post-publication identity check are intentionally retained without a Catalog descriptor for the
startup reconciliation phase.

## D1b-3B-2B owned lifecycle reconciliation smoke

`Tests/run-owned-dictionary-lifecycle-reconciliation-smoke.sh` runs the same synthetic lifecycle
matrix in Debug with ASan/UBSan and in optimized Release. It verifies Catalog-provenance blocking,
known partial cleanup, verified-to-final no-replace recovery, full-SHA orphan registration,
identity/conflict preservation, interrupted index downgrade, OpenResource index eligibility,
descriptor-relative owned removal, PendingDeletion restore/cleanup, rollback, cancellation,
durability uncertainty, idempotence, and the startup publication barrier. It uses isolated
temporary roots and synthetic payloads only; it never reads Application Support, private
dictionaries, `local.json`, the network, or Keychain.

The reported number is **total runtime assertions**, not a count of independent security
behaviours. The runner also reports assertion categories for real POSIX filesystem operations,
real `renameatx_np`, Catalog transactions, SHA-256, injected failures, publication barriers, and
helper-only checks. Conflicting or structurally unknown owned directories are preserved in place;
2B does not recursively delete them or introduce a general quarantine/journal framework.

- Install the ignored developer configuration with `scripts/install-private-local-config.sh`, then start once with the normal HOME and once with an isolated HOME containing no external configuration; confirm five-dictionary and friendly empty states respectively, and confirm neither App Bundle contains `local.json`.
- Import an MDX, cancel once, then complete an import and attempt a duplicate import; confirm the original file is unchanged.
- Build an index, request cooperative cancellation, exercise a controlled failure and retry, and confirm pending/indexing/cancelling/ready/failed wording.
- Query a preferred hit, a managedLocal-only hit, and an AI fallback; confirm the existing priority and formatter behavior is unchanged.
- Reorder within preferred and normal groups, restart, then restore defaults; confirm enabled state and index metadata are unchanged.
- Remove a managedLocal dictionary and confirm its original import source, saved snapshots, and existing Obsidian Markdown remain intact.
- Check global Option-Space, Accessibility permission guidance, in-app selection, “了解更多”, manual input, and standard editing shortcuts.
- Resize the dictionary manager at common window sizes in light and dark appearances; confirm columns, buttons, dates, tooltips, focus order, and indeterminate progress remain readable.
- Switch the query panel between light and dark appearances while an Oxford and managedLocal result is visible; confirm pronunciation, definitions, examples, translations, and source emphasis remain readable without re-querying.
- With a non-secret test Provider, compare “测试连接” with one formal word request; confirm success, timeout, cancellation, HTTP failure, and malformed JSON all leave the loading state and expose only actionable, sanitized errors.
- With networking unavailable, confirm all local dictionaries and sentence glossary continue working and no repeated permission or credential prompt appears.
