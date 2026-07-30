# Resource Center

Resource Center is the native open-resource surface inside **词典管理**. It does not replace the
five user-provided preferred dictionaries and never downloads, distributes, reorders, or changes
their specialized formatters.

## Safe default and empty states

The production build currently has no reviewed manifest endpoint, payload host, or trusted public
key. Resource Center therefore shows a non-blocking “not configured” state. Manual MDX import,
installed dictionaries, preferred lookup, and application startup continue to work without a
network, a remote catalog, or any dictionary.

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

Remote resources support only an uncompressed, single-file MDX payload and
`generic-mdict-v1`. MDD, images, audio, archives, scripts, and arbitrary formatters are unsupported.
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

## License and provenance

Before installation, Resource Center displays the license name and version, license URL, source
project/publisher reference, version, size, languages, and redistribution statement. An entry
without license text/evidence or explicit redistribution and mirroring permission is rejected by
manifest validation. “Available on a website” is never treated as redistribution permission.

The repository and App bundle contain no commercial MDX/MDD, user dictionary, production payload,
or private signing key.

## Offline behavior

Installed dictionaries remain available offline. The application persists only rollback-resistant
verified-manifest state; manifest catalog bytes are session-only in M23. Therefore a fresh offline
launch shows the catalog-unavailable state instead of trusting an unverifiable cache. Removing that
state never removes installed dictionaries.
