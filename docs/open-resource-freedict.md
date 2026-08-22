# FreeDict eng-zho local conversion record

This document describes the retained FreeDict converter and the transformation notice for existing
locally derived SQLite databases. FreeDict is visible in the v0.1 Starter Catalog after its fixed
official 2025.11.23 payload passed download, install, restart, forward/reverse query, removal and
reinstallation gates. Its converter and lifecycle remain fail-closed if the upstream archive at the
dated URL no longer matches the reviewed byte count and digest.

## Fixed source

- Resource: English-中文 FreeDict+WikDict dictionary (`eng-zho`)
- Version/date: `2025.11.23`
- Official directory: <https://download.freedict.org/dictionaries/eng-zho/2025.11.23/>
- Official archive: `freedict-eng-zho-2025.11.23.stardict.tar.xz`
- Exact bytes: `1672048`
- SHA-256 fixed by LocalDictionary: `9dbae6bb5558906cc05f1e573bee2deab8b6e09adfb16fc496288926882435af`
- Official SHA-512: `059f9aca26fdc3a5a2c0c0e8fc92e111a34bf8fd438f70d267cccf35f5e47a2d45c46650999a1b3a48c3bffc3e16e0db897232128fe822d1bc59cf34f40b395c`
- Source word count: `26660`

The `.ifo` file identifies Karl Bartel as publisher, automatic creation by WikDict, and base data
from Wiktionary through DBnary. It declares Creative Commons Attribution-ShareAlike 3.0 Unported:
<https://creativecommons.org/licenses/by-sa/3.0/legalcode>.

The preferred TEI source archive was audited first. Its `eng-zho.tei` contains an external
`DOCTYPE` declaration. LocalDictionary's frozen parser boundary rejects every DOCTYPE, so the App
uses the same fixed release's official StarDict archive instead of weakening XML security.

## Transformation `freedict-stardict-v1` version 1

1. Verify exact download length, SHA-256 and official SHA-512.
2. Stream XZ/TAR with system libarchive; accept only the six compiled member names, regular-file
   types, and exact sizes. Reject links, additional members, traversal and expansion beyond 16 MiB.
3. Validate `.ifo` version `3.0.0`, book name, word count, index size, `sametypesequence=h`, date,
   license URL, and provenance markers.
4. Stream the inner GZIP index to a bounded 464,739-byte file.
5. Parse each StarDict index record as UTF-8 headword, big-endian dictionary offset and bounded
   size. Read the matching HTML record by offset.
6. Retain a normalized/display English headword, reliable grammar label, bounded plain Chinese
   definition, source ordinal/offset, resource/version/hash, and transformer version. Do not retain
   raw HTML. Pinyin-only and placeholder translations are skipped and counted.
7. Insert entries and bounded Chinese 1–4-gram terms in transactions of at most 4,096 entries.
8. Run SQLite integrity and metadata checks, hash the result, fsync files/directories, and publish
   the versioned SQLite and receipt by one directory rename before setting Catalog `ready`.

The output schema version is `1`. It contains `metadata`, `entries`, and `terms`. The receipt binds
the official URL/digest, license/attribution, transformer ID/version, output schema/publication/hash,
and integrity result. Rebuilding from the same source and transformer is supported; SQLite byte
identity is not promised across operating-system SQLite versions.
