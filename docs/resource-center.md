# Resource Center

Resource Center is the native open-resource surface inside **词典管理**. It does not replace the
five user-provided preferred dictionaries and never downloads, distributes, reorders, or changes
their specialized formatters.

## Live language-pair catalog

Resource Center reads the current Native/Learning language pair whenever it opens or the setting
changes. A refresh requests FreeDict's official JSON directory and selects only dictionaries whose
direction matches that pair. For Chinese/English it also presents the current official CC-CEDICT
export, giving one resource in each direction. WordNet and GCIDE remain optional English-learning
supplements. Unrelated static resources are not shown.

| Resource | Direction/category | Version source | Typed source format | Official host | Content license |
| --- | --- | --- | --- | --- | --- |
| FreeDict | Current Native/Learning pair, when available | live official directory | `freedict-stardict-tar-xz` | `download.freedict.org` | source-specific; shown before install |
| CC-CEDICT | Chinese → English when the active pair is Chinese/English | current official editor export | `cc-cedict-text-gzip` | `cc-cedict.org` | CC-BY-SA-4.0 |
| Princeton WordNet | English semantic lexicon | `3.0` | `wordnet-data-tar-gzip` | `wordnetcode.princeton.edu` | WordNet-3.0 |
| GNU GCIDE | English monolingual | `0.54` | `gcide-markup-tar-xz` | `ftp.gnu.org` | GPL-3.0-or-later |

Versions, exact byte counts, and per-release hashes are not compiled into the App for live entries.
The FreeDict SHA-512 supplied by its directory is verified. CC-CEDICT does not publish a checksum
through its current editor export, so the App computes the downloaded SHA-256 and records it in
the local installation receipt for restart/removal consistency.

WordNet and GCIDE are English-only and are skipped by the Chinese query planner. FreeDict supports
English lookup and a locally derived Chinese reverse index. Resource Center recommends starters
against the current Native/Learning language pair. Browsing Resource Center fetches directory
metadata only; a dictionary payload download begins only after the user clicks Install. Downloads
must remain HTTPS on the corresponding official FreeDict or CC-CEDICT project host.

Only a manifest that passes the existing detached Ed25519 signature, strict schema, rollback,
license, redistribution, HTTPS, and host checks is shown. A listed payload then passes the signed
host/app host intersection, size and capacity admission, streaming SHA-256, secure staging,
immutable receipt, directory-fd publication, Catalog v3, fd-bound indexing, sealed index
publication, and fd-bound query chain.

## User-provided MDX

Choose **导入本地 MDX…**, select exactly one regular `.mdx` file, review its necessary metadata,
and confirm “我有权在本机使用该词典文件”. This statement does not claim redistribution rights.
The application does not recursively scan the disk, inspect sibling MDD files, upload the
dictionary, or store its original absolute path in the UI or Catalog. The source is copied into
App-managed storage and becomes query eligible only after the sealed local index succeeds.

Duplicate content is not copied silently. The user may cancel, reveal the existing dictionary, or
explicitly import the same content as an independent dictionary after confirming local-use rights.
Safe replacement of a user-provided dictionary is not inferred from a matching filename or digest.

## Installation, update, and removal

The legacy signed-manifest path continues to support its reviewed single-file MDX contract. The
starter path is separate and uses an explicit typed source format; none is presented as
MDX. Each converter accepts only its reviewed archive/text/JSONL/markup subset. MDD, images, audio,
scripts, arbitrary archives, and arbitrary formatters remain unsupported.
Download progress can be cancelled; partial staging is removed by the existing staging operation.
Failures never publish a query-eligible descriptor.

Updates are user initiated. The current version remains the only query-eligible descriptor while
the higher signed resource revision downloads and builds a sealed index. The Catalog switches to
the new ready version before identity-checked removal of the old version. Indexing or download
failure leaves the current version available. A lower revision, or the same revision with a
different SHA-256, is rejected.

Removal uses the existing receipt, Catalog identity, lifecycle lease, removal inventory, and
generation-scoped cache invalidation. Objects whose identity cannot be proven are preserved for
audit rather than deleted.

## FreeDict local conversion

After the current archive passes the official-directory SHA-512, the App uses the macOS system
libarchive library to stream XZ/TAR and the inner GZIP index. It accepts only regular files under
the declared language-pair directory, rejects traversal and links, applies compressed/expanded
size limits, and never asks a shell to extract data. The `.ifo` format and entry bounds are checked
before conversion.

The bounded StarDict index is parsed as NUL headword plus big-endian offset/size. Records are read
by bounded offsets. The converter retains bounded headwords, part of speech, definitions and source
identity for the discovered direction. English→Chinese applies the stricter Chinese-gloss filter;
other language pairs keep bounded non-empty definition text. Entry counts come from the downloaded
`.ifo` and official directory instead of a compiled release constant.

The temporary SQLite contains `metadata`, `entries`, and `terms`, with schema version, resource and
source identities, transformer version and publication identity. `PRAGMA integrity_check`, metadata
binding, file hashes, `fsync`, and directory-atomic publication precede Catalog `ready`. The same
SQLite provides fallback English lookup, long-text vocabulary definitions, and Chinese reverse
candidates. Preferred dictionaries and other user imports remain ahead of it.

Legacy pinned-fixture details remain in [open-resource-freedict.md](open-resource-freedict.md) for
regression tests; they do not drive the live catalog.

## Other typed local conversions

- CC-CEDICT accepts bounded GZIP text in the documented CC-CEDICT line grammar, retains simplified
  and traditional headwords, pinyin and bounded English definitions, and rejects malformed or
  over-limit records.
- Kaikki accepts bounded line-delimited JSON objects from the fixed Chinese Wiktionary English-entry
  snapshot. It reads only reviewed lexical fields and never evaluates embedded markup or scripts.
- WordNet accepts only the reviewed database archive members and parses bounded `data.*` records
  for English definitions, examples and semantic relations.
- GCIDE accepts the reviewed GNU XZ/TAR layout and a bounded subset of GCIDE markup for headwords,
  definitions and lexical relations; markup is data, never executable content.

All retained converter paths share capacity admission, cancellation, utility-QoS yielding and thermal pacing,
temporary SQLite construction, bounded transactions, `integrity_check`, receipt binding, atomic
publication and stale-index rejection. Fixed converter fixtures cover all retained formats, including
hostile archives, traversal/link attempts, malformed lengths, excessive records and oversized
entry text. Complete upstream payloads are neither committed to Git nor bundled in the App.

## License and provenance

Before installation, Resource Center displays the license name and version, license URL, source
project/publisher reference, version, size, languages, and redistribution statement. An entry
without license text/evidence or explicit redistribution and mirroring permission is rejected by
manifest validation. “Available on a website” is never treated as redistribution permission.

The repository and App bundle contain no commercial MDX/MDD, user dictionary, starter dictionary
body, production payload, or private signing key. Starter content is downloaded only after the user
clicks. Its exact license, source project and attribution are shown in the UI, recorded in the
installation receipt and summarized in `THIRD_PARTY_NOTICES.md`.

## Offline behavior

Installed dictionaries remain available offline. The application persists only rollback-resistant
verified-manifest state; manifest catalog bytes are session-only in M23. Therefore a fresh offline
launch shows the catalog-unavailable state instead of trusting an unverifiable cache. Removing that
state never removes installed dictionaries.
