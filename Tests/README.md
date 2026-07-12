# Tests

Phase 2 was exercised against the selected real Oxford MDX with the documented 20-word set. Additional checks cover ASCII case fallback, English and curly-quote cleanup, trailing punctuation cleanup, read-only index reuse, SQLite integrity, and an in-process cache hit. Fixture-based automated tests remain future work because dictionary files must not be copied into the repository.
