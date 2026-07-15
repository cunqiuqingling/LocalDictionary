# Tests

Phase 2 was exercised against the selected real Oxford MDX with the documented 20-word set. Additional checks cover ASCII case fallback, English and curly-quote cleanup, trailing punctuation cleanup, read-only index reuse, SQLite integrity, and an in-process cache hit.

`run-multidictionary-smoke.sh` reads the ignored machine-local configuration and tests all five fixed dictionaries through the production SQLite core and native formatters. It writes only ignored fixtures and temporary Markdown notes below `.build/`; no dictionary or user note is copied or modified. The smoke test also verifies multi-source Markdown sections, duplicate prevention, and isolation of a missing dictionary path.

`run-dictionary-catalog-smoke.sh` tests the versioned catalog model, atomic primary/backup persistence, corruption recovery, relative-path validation, optional legacy configuration loading, stable priority sorting, and idempotent five-dictionary legacy adaptation. It uses only temporary placeholder files and a minimal temporary SQLite metadata table; it never opens a real MDX or invokes the production index builder.

Stage A stores `catalog-v1.json` and `catalog-v1.backup.json` under the app's user Application Support `LocalDictionary/Catalog` directory. The app now starts with an empty catalog when bundled `local.json` is absent; when it is present, the existing five dictionaries remain on the unchanged legacy query dispatcher and are represented only by path-free `legacyReference` catalog records. Dictionary management is read-only in this stage: importing, downloading, editing query order, and deleting dictionaries are not yet supported.
