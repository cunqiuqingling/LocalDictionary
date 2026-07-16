# Tests

Phase 2 was exercised against the selected real Oxford MDX with the documented 20-word set. Additional checks cover ASCII case fallback, English and curly-quote cleanup, trailing punctuation cleanup, read-only index reuse, SQLite integrity, and an in-process cache hit.

`run-multidictionary-smoke.sh` reads the ignored machine-local configuration and tests all five fixed dictionaries through the production SQLite core and native formatters. It writes only ignored fixtures and temporary Markdown notes below `.build/`; no dictionary or user note is copied or modified. The smoke test also verifies multi-source Markdown sections, duplicate prevention, and isolation of a missing dictionary path.

`run-dictionary-catalog-smoke.sh` tests the versioned catalog model, atomic primary/backup persistence, corruption recovery, relative-path validation, optional legacy configuration loading, stable priority sorting, and idempotent five-dictionary legacy adaptation. It uses only temporary placeholder files and a minimal temporary SQLite metadata table; it never opens a real MDX or invokes the production index builder.

Stage A stores `catalog-v1.json` and `catalog-v1.backup.json` under the app's user Application Support `LocalDictionary/Catalog` directory. The app starts with an empty catalog when the developer-only external `LegacyConfig/local.json` is absent; when it is present, the existing five dictionaries remain on the unchanged legacy query dispatcher and are represented only by path-free `legacyReference` catalog records. The private file is never copied into Debug or Release App Bundles.

`run-local-configuration-isolation-smoke.sh` uses an isolated HOME to verify the single production lookup location, safe missing/corrupt behavior, explicit test-only URL injection, five path-free legacy descriptors, idempotent adaptation, and the absence of legacy index writes. `run-app-bundle-audit-smoke.sh` verifies that clean bundles pass while private configuration, MDX/MDD, SQLite/Catalog/PendingDeletion data, user paths, bearer headers, and synthetic secret fields fail without disclosing matched values or modifying the bundle. It also exercises the developer-only private-config installer in an isolated HOME.

`run-dictionary-import-smoke.sh` exercises the macOS-only B1 managed import boundary with generated header-only MDX fixtures and small placeholder MDD files. It covers strict MDD basename pairing, preview metadata, cancellation, disk-space rejection, disappearing sources, SHA-256 duplicate detection, staging rollback, relative Catalog paths, and the absence of index artifacts. B1 only copies files and creates `pendingIndex` records; imported dictionaries are not connected to production queries.

`run-dictionary-indexing-smoke.sh` exercises the B2 managed-index state machine with generated source bytes and an injected SQLite builder. It covers success, failure and retry, cooperative cancellation, one-at-a-time execution, source fingerprint and disk-space rejection, integrity validation, interrupted-build recovery, relative Catalog paths, and protection of an existing final index. B2 produces verified independent indexes only after explicit user action; ready managed dictionaries are still excluded from production queries.

`run-managed-dictionary-query-smoke.sh` exercises the B3 preferred-to-managed fallback policy, canonical and legacy generic formatter identifiers, B1 root-level and future `source/` managed MDX layouts, path/symlink escape rejection, stable Catalog ordering, state filtering, isolated failures, source SHA-256 and read-only SQLite validation, and safe managed dictionary snapshots for Markdown. It uses generated placeholder bytes, a temporary SQLite metadata table, and a mock managed runtime; it never opens a commercial MDX or accesses the network.

`run-generic-mdict-formatter-security-smoke.sh` validates the B3 libxml2 safety boundary with synthetic HTML. It verifies basic headings, paragraphs, lists, emphasis and code while discarding scripts, embedded content, hidden nodes and URL-bearing attributes, and enforcing raw-byte and DOM-depth limits.

`run-dictionary-ordering-removal-smoke.sh` exercises the B4 same-level ordering and managed removal boundaries. It covers persistent preferred/normal/fallback ordering, cross-level rejection, save rollback, stable default restoration, legacy adapter order preservation, managed-only two-phase removal, Catalog rollback, interrupted-removal recovery, deferred cleanup, runtime release, and absolute/traversal/other-UUID/symlink path rejection. It uses generated placeholder files in a temporary directory and never opens a commercial dictionary, accesses the network, or modifies an Obsidian note.

`run-dictionary-manager-ui-state-smoke.sh` covers the C1 dictionary-manager presentation model and a lightweight in-process AppKit layout pass. It verifies user-facing source/query/status wording, cooperative cancellation and removal states, index-action titles and disabled reasons, table-width assumptions, empty/populated manager layouts, import-preview layout, and the absence of internal path/SQLite/Catalog details in manager error messages. It does not launch the product, access a dictionary, or use the network.

`run-ripemd128-miniz-smoke.sh` compiles the project RIPEMD-128 adapter with the fixed LibTomCrypt source and exercises the official standard vectors, segmented and multi-block updates, independent contexts, idempotent finalization, and sanitizer checks. It also validates the fixed miniz subset with synthetic round-trip and truncated-input decompression, plus the mdict-cpp encrypted key-info boundary against an independent synthetic reference; no dictionary or network is used.

`run-third-party-vendor-smoke.sh` verifies the exact reviewed vendor file set, recorded SHA-256 values, license files, Git visibility, forbidden dependency exclusions, and the absence of build/test references to the ignored research checkout, old RIPEMD sample, miniz ZIP code, or turbobase64.

`run-open-source-compliance-smoke.sh` performs an offline source-release check. It verifies the exact official GPLv3 root license text, GPL-3.0-only scope statements, third-party notices and fixed provenance, vendored licenses and hashes, privacy/security documentation, D1 policy placeholders, absence of private paths and obvious secret values in public documentation, and consistency between clean-build, AI-network, and private `local.json` statements. It does not access the network, user Application Support, Keychain, dictionaries, or build products.

The repository is currently source-only and targets macOS 15.0+ on arm64. A clean clone builds from tracked `ThirdParty/vendor` files without a submodule, a separate mdict-cpp clone, Homebrew dependencies, or private `local.json`. The only runtime permission required for selection lookup is Accessibility; the App does not request screen recording, microphone, or system audio recording permission.

## C1 manual acceptance checklist

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
