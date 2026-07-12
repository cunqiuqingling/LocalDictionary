# MDictCore

Native, offline MDict indexing and random-access lookup code belongs here.

`SQLiteDictionaryCore` is the phase-2 minimal core. It builds a source-fingerprinted SQLite index once, opens it read-only on later launches, loads only MDict block metadata, and reads individual record blocks on demand. Exact lookup, ASCII case fallback, simple surrounding punctuation cleanup, and a 64-entry/8 MiB LRU record cache are implemented.

`ValidationCLI` remains the phase-1 compatibility probe. No AppKit or application UI code exists in this directory.
