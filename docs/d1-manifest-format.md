# D1 resource Manifest v1

This document defines the security boundary implemented in D1b-1. It describes an
offline verification foundation only: the App does not ship a resource Manifest,
download a resource, modify the dictionary Catalog, install a dictionary, or build
an index in this stage.

## Signed bytes and files

The Manifest is one UTF-8 JSON document. The detached Ed25519 signature covers the
downloaded Manifest bytes exactly as received. Verification never signs or verifies
a decoded, reserialized, reformatted, or canonicalized representation. Changing
whitespace, key order, or a final newline therefore invalidates an existing
signature even if the JSON meaning is unchanged.

The verifier rejects an empty Manifest, invalid UTF-8, a UTF-8 BOM, a non-object
root, trailing data, and input above the injected size policy (1 MiB by default).
The signature is verified before the JSON bytes are parsed or used.

## Detached signature envelope

All multi-byte integers use network byte order (big endian). A v1 sidecar is laid
out as follows:

| Offset | Size | Meaning |
|---:|---:|---|
| 0 | 8 | ASCII magic `LDMSIG01` |
| 8 | 2 | Signature envelope version, `1` |
| 10 | 2 | Algorithm identifier, `1` for Ed25519 |
| 12 | 2 | `keyID` byte length |
| 14 | 2 | Signature byte length, exactly `64` |
| 16 | variable | ASCII `keyID` |
| following | 64 | Raw Ed25519 detached signature |

The complete sidecar is limited to 4 KiB. `keyID` is 1–64 ASCII bytes and may use
only letters, digits, period, underscore, and hyphen. Unknown versions or
algorithms, invalid lengths, truncation, overflow, and trailing bytes are rejected.
The sidecar cannot introduce a public key: `keyID` can only select a key already in
the verifier's injected trust store.

LocalDictionary uses CryptoKit `Curve25519.Signing.PublicKey` for Ed25519
verification. D1b-1 intentionally ships an empty production trust store. Synthetic
tests generate TEST-ONLY keys at runtime. No production or test private key is
stored in the repository, CI, App Bundle, or repository secrets. A future reviewed
release must inject production public keys explicitly; trust-on-first-use is not
implemented.

## Manifest v1 object

Every object uses a closed field set. Unknown fields, missing required fields,
explicit `null`, duplicate keys, type substitution, floating-point or negative
integers where unsigned integers are required, and `UInt64` overflow are rejected.
The strict parser also limits nesting depth, member and array counts, string byte
length, and total parsed values.

The root object contains exactly these fields:

| Field | Type and rule |
|---|---|
| `schemaVersion` | positive integer; v1 accepts only `1` |
| `manifestVersion` | positive unsigned integer |
| `issuedAt` | strict RFC 3339 UTC timestamp |
| `expiresAt` | strict RFC 3339 UTC timestamp later than `issuedAt` |
| `keyID` | must equal the verified sidecar `keyID` |
| `minimumAppVersion` | strict 1–4 component numeric version |
| `resources` | array of resource objects |
| `revokedResources` | array of revocation range objects |

Each resource object contains the following fields. Conditional direct-download
fields remain part of the closed schema but must be absent for `officialPageOnly`.

| Field | Type and v1 rule |
|---|---|
| `resourceID` | restricted ASCII token, unique in the Manifest |
| `resourceRevision` | positive unsigned integer |
| `displayName` | bounded non-empty text |
| `version` | bounded ASCII version token |
| `languages` | non-empty, bounded, unique language-tag array |
| `description` | bounded non-empty text |
| `category` | bounded ASCII token |
| `queryLevel` | exactly `fallback` |
| `distributionMode` | `mirroredDownload` or `officialPageOnly` |
| `sourceProjectURL` | absolute HTTPS URL |
| `officialDownloadPage` | absolute HTTPS URL |
| `downloadURL` | required only for mirrored downloads |
| `allowedDownloadHosts` | required only for mirrored downloads |
| `fileName` | safe ASCII `.mdx` basename for mirrored downloads |
| `archiveFormat` | exactly `none` for mirrored downloads |
| `compressedSize` | positive unsigned integer for mirrored downloads |
| `maximumDownloadedSize` | policy-bounded unsigned integer for mirrored downloads |
| `maximumExpandedSize` | policy-bounded unsigned integer for mirrored downloads |
| `sha256` | 64 lowercase hexadecimal characters for mirrored downloads |
| `licenseName` | bounded non-empty text |
| `licenseVersion` | bounded non-empty text |
| `licenseURL` | absolute HTTPS URL |
| `attribution` | bounded non-empty text |
| `notice` | strict notice object |
| `redistributionAllowed` | Boolean |
| `mirroringAllowed` | Boolean; requires redistribution permission |
| `modificationAllowed` | Boolean |
| `formatConversionAllowed` | Boolean |
| `commercialUseAllowed` | Boolean |
| `shareAlikeRequired` | Boolean |
| `minimumAppVersion` | strict numeric App version |
| `dictionaryFormat` | exactly `generic-mdict-v1` |
| `expectedEntryCount` | strict minimum/maximum object |
| `status` | `active` or `deprecated` |
| `reviewedAt` | strict RFC 3339 UTC timestamp |
| `reviewEvidence` | non-empty array of strict evidence objects |

`notice` contains only `kind` (`inline`) and bounded `text`.
`expectedEntryCount` contains only positive `minimum` and `maximum`, with maximum
greater than or equal to minimum. Each `reviewEvidence` item contains only bounded `kind`,
an HTTPS `url`, and a lowercase SHA-256 digest.

Each revocation contains only `resourceID`, positive `minimumRevision`,
`maximumRevision`, bounded `reasonCode`, and strict UTC `effectiveAt`. Overlapping
ranges for one resource and a range that revokes an active listed revision are
rejected.

## URL, host, filename, date, and version rules

URLs must be absolute HTTPS URLs without user information or fragments. Empty,
non-ASCII, IP-literal, malformed, or single-label hosts are rejected. Only the
default HTTPS port is accepted. A mirrored `downloadURL` host must be present in
the unique normalized `allowedDownloadHosts` list.

Mirrored filenames are 1–128 ASCII bytes, are basenames only, and contain only
letters, digits, period, underscore, and hyphen. Leading or trailing periods,
trailing spaces, `..`, path separators, control characters, and Unicode confusable
characters are rejected.

Dates use exactly `yyyy-MM-dd'T'HH:mm:ss'Z'`; local offsets and lenient dates are
not accepted. `issuedAt` may not exceed the injected clock plus the allowed skew.
An expired Manifest remains identifiable as expired but cannot be treated as a new
installation/update source by a later consumer. App versions are compared as
numeric components, not lexicographically.

## Verification and rollback state

The public verification entry follows this order:

1. bound and parse the binary signature sidecar;
2. validate `keyID` and find an injected trusted public key;
3. verify the Ed25519 signature over raw Manifest bytes;
4. bound and strictly parse UTF-8 JSON;
5. validate schema, fields, semantics, dates, App version, uniqueness, and
   revocations;
6. compute the raw-byte SHA-256 and enforce rollback state;
7. return a verified value and a state candidate.

Preparation is pure and never changes persistent state. Only an explicit
`commitVerifiedState` call advances the rollback store. A higher
`manifestVersion` is accepted. The same version is idempotent only when digest and
`keyID` are unchanged. A lower version, changed digest, or unexpected key change at
the same version is rejected.

The rollback store is isolated at
`Application Support/LocalDictionary/ResourceCenter/ManifestState` by default and
is injectable for tests. It uses a primary and backup JSON file, temporary files,
file and directory `fsync`, same-filesystem atomic rename, mode `0600` files, and a
mode `0700` directory. Corrupt or inconsistent state fails closed rather than being
treated as first use. Tests operate only in temporary directories.

## Deliberate D1b-1 boundaries

- Manifest v1 does not allow `externalReference`; that remains a reserved local
  Catalog source kind.
- Manifest v1 rejects `preferred`, `normal`, `generic-mdict.v1`, Swift type names,
  scripts, plugins, commands, and arbitrary formatter identifiers.
- Existing local Catalog compatibility for the legacy formatter alias is unchanged.
- `DictionaryDescriptor` and `catalog-v1.json` are not reused or modified. The
  current synthesized Catalog decoding behavior for unknown fields requires a
  separate compatibility review.
- No real `resources.json`, network client, downloader, installer, indexer, query
  integration, or UI is included in this stage.
- Before real resources are enabled, the existing C++ MDict allocation boundaries
  (materialized key lists and record-block allocation before the Swift HTML limit)
  remain a P1 item for D1b-3.

All examples and automated tests use synthetic `.invalid` hosts, identifiers,
digests, metadata, and runtime-generated TEST-ONLY keys.
