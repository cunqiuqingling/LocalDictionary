# Open-resource installation receipt (D1b-3B-2A)

An open resource has two deliberately separate authorities:

- `resource-installation.json` is the immutable, verified installation identity. It records the
  local installation UUID, signed resource/manifest identity, payload hash and byte count,
  formatter, language and licence metadata. It never records lifecycle or query settings.
- Catalog v2 is the mutable lifecycle authority. Its first installed record is an enabled,
  fallback, `pendingIndex` `openResource` descriptor with
  `appManagedOpenResource` ownership.

The downloader creates the receipt in the same private operation directory as `payload.mdx`.
Both files are fsynced before that directory is atomically renamed to `verified-*`. Installation
then reopens the verified directory by descriptor, rejects any extra top-level entries, validates
both regular files and their identities, hashes the payload, parses the bounded receipt, and
publishes the already-verified directory with `renameatx_np(RENAME_EXCL)` to
`Dictionaries/<dictionaryID>`.

The Catalog is saved only after the final directory and its parent are durable. If that Catalog
save fails, the final directory and receipt remain intact and the operation reports a recoverable
post-publication error. D1b-3B-2B startup reconciliation now revalidates and registers that final
orphan as disabled / fallback / pending-index when its full payload identity remains valid.

Catalog v2 uses `catalog-v2.json` and `catalog-v2.backup.json`. It preserves v1 files without
rewriting them, explicitly migrates legacy and locally imported descriptors in memory, and rejects
v1 open-resource records because they do not carry a trusted receipt identity.

## R1 transaction and publication rules

Only a genuinely missing Catalog may create an empty v2 Catalog. Corrupt or unsupported v2/v1
input remains non-writable: startup adaptation and every Catalog writer refuse to overwrite that
evidence. Each writer uses one short mutation critical section that reloads the latest durable
Catalog, changes only its target state, validates it, and publishes it. Download, copying,
indexing, and query work stay outside this lock.

For an existing valid v2 primary, `catalog-v2.backup.json` is published from the *previous* valid
primary before the new primary is published. A first v2 save does not fabricate a backup, and a
mutation recovered from a valid backup does not overwrite that backup. A failed transaction is
therefore not revived by treating its new bytes as a backup.

The verified staging sidecar is bounded-read and matched field-for-field against the immutable
installation identity before publication. The source name is rebound to the verified directory fd
immediately before `renameatx_np(RENAME_EXCL)`. After publication, the final directory identity,
payload hash, receipt identity, modes, link counts, and exact two-entry layout are revalidated
before Catalog commit. A final object that fails post-publication verification remains on disk
without a Catalog descriptor for conservative startup reconciliation.

## D1b-3B-2C registration and fallback query

Final filesystem publication remains the existing fd-anchored `RENAME_EXCL` operation. Catalog
registration now also obtains the shared per-dictionary lifecycle exclusive permit, publishing a
new process-local generation but no query runtime for the initial `pendingIndex` descriptor.

After explicit indexing, an OpenResource joins offline fallback only when all of these are true:
`sourceKind == openResource`, `storageOwnership == appManagedOpenResource`, query level is
`fallback`, the descriptor is enabled and `ready`, its relative paths/receipt remain valid, and a
current lifecycle lease can be acquired. The fixed order is preferred legacy dictionaries, user
managedLocal dictionaries, then OpenResource fallback. A fallback miss or isolated runtime error
does not make an AI request; AI remains user initiated. Results still use the existing bounded
generic MDict sanitizer and never render raw HTML, load resources, or expose paths or receipt
text. Production manifest endpoints and payload hosts remain empty, and no real resource is
bundled.
