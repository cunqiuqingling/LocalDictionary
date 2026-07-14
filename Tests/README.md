# Tests

Phase 2 was exercised against the selected real Oxford MDX with the documented 20-word set. Additional checks cover ASCII case fallback, English and curly-quote cleanup, trailing punctuation cleanup, read-only index reuse, SQLite integrity, and an in-process cache hit.

`run-multidictionary-smoke.sh` reads the ignored machine-local configuration and tests all five fixed dictionaries through the production SQLite core and native formatters. It writes only ignored fixtures and temporary Markdown notes below `.build/`; no dictionary or user note is copied or modified. The smoke test also verifies multi-source Markdown sections, duplicate prevention, and isolation of a missing dictionary path.
