# Owned dictionary lifecycle reconciliation (D1b-3B-2B)

Startup loads the explicit Catalog provenance first. Corrupt or unsupported current-generation
Catalog state blocks all owned-filesystem mutation: Staging, Dictionaries and PendingDeletion are
left untouched. Missing, valid primary, valid backup and in-memory v1 migration may reconcile.
Long directory scans and payload hashes run outside the Catalog mutation lock; a short final
`mutate()` reloads the latest durable Catalog and commits only if the prepared snapshot is still
current.

Before any managed query, indexing, removal, manager or panel runtime receives a Catalog, startup
processes known `.partial-*` operations, verified OpenResource directories, final owned
directories, PendingDeletion and interrupted index state. Unknown structures and identity
conflicts are preserved in place with fixed issue codes. This first version deliberately uses no
general journal and no quarantine move: preservation avoids destructive guesses while a future
stage can define a broader quarantine policy.

## Authority and recovery

`resource-installation.json` is the immutable OpenResource installation identity. Catalog v2 is
the mutable authority for enabled state, query level/order, lifecycle state, index metadata and
relative paths. Reconciliation never derives one authority from an untrusted display name.

- A valid `verified-*` directory is bounded-read, fully hashed and published with
  `renameatx_np(RENAME_EXCL)`. Operation names are accepted only as canonical lowercase UUID
  components. The validated directory identity (device, inode, owner and type) is rebound at
  the source name before rename and again at the destination after rename. Both parent
  directories are fsynced before Catalog registration.
  A post-rename fsync failure leaves the final object unregistered during that run; a later
  startup treats the surviving object as an ordinary durability-uncertain orphan.
- A complete final OpenResource orphan receives a disabled, fallback, `pendingIndex` descriptor
  only after full sidecar/payload identity validation and SHA-256. Duplicate resource or
  dictionary identities are never selected automatically.
- A Catalog-owned directory that is missing becomes disabled `missingResources`. A present but
  invalid sidecar, payload, path or inventory becomes disabled `corrupt`; the directory and
  identity record are preserved.
- A matching normal installation is accepted without rehashing every large payload on every
  launch. Full SHA is reserved for orphan/recovery trust establishment.

## Index and removal recovery

Both `appManagedImported` and `appManagedOpenResource` are explicitly indexable and removable.
`externalReference`, `bundledReadOnly` and legacy references never enter owned deletion. Open
resources remain non-queryable in this stage.

An interrupted `indexing` state returns to `pendingIndex`; the exact
`index/dictionary.sqlite.building` component is removed only after a fresh fd-bound complete
inventory confirms that no unknown index entry exists, then directory fsync. `ready` without a final index also returns to `pendingIndex` and clears stale index
metadata. A final index beside `pendingIndex` never causes automatic promotion to `ready`.

Removal suspends the current managed runtime, revalidates the owned directory by fd, carries its
device/inode/owner/type identity across the stage and rollback names, moves the whole UUID
directory to `PendingDeletion/<dictionaryID>` with no-replace rename and fsyncs both parents.
Catalog deletion then commits. A Catalog failure restores the same inode no-replace; a
successful Catalog commit followed by cleanup failure leaves PendingDeletion for the next
startup. Existing Obsidian or saved content snapshots are not touched.

If staging fails, the coordinator does not resume merely because staging failed. It first opens the
canonical final name with `O_NOFOLLOW`, validates the owned directory, and requires its
device/inode/owner/type identity to equal the identity recorded in the original removal plan.
Only that exact match resumes the runtime. Missing, replaced, unreadable, or post-publication
uncertain names remain suspended for the rest of the process; their Catalog descriptor is retained
and the next startup reconciliation revalidates the filesystem.

At startup, a matching Catalog descriptor causes a validated PendingDeletion directory to be
restored. No matching descriptor means the removal already committed, so only a completely
inventoried known owned structure is unlinked. Unknown entries, symlinks, hardlinks, identity
mismatches, target conflicts and durability failures preserve the directory for retry. Repeating
reconciliation is idempotent.

Directory enumeration failure is an incomplete transient observation, not proof of structural
corruption. If any owned lifecycle inventory ends with `directoryEnumerationFailure`, that entire
reconciliation run discards all proposed Catalog changes and does not enter Catalog mutation. Safe
filesystem operations that already completed are preserved for the next startup rather than being
dangerously rolled back. By contrast, a complete inventory that finds an unknown entry remains a
structural error: the directory is preserved and the descriptor may be durably disabled. Final
fast-path full-SHA verification remains deferred to D1b-3B-3.

## D1b-3B-2C process-local lifecycle leases

The App now creates one shared, process-local lifecycle coordinator after startup reconciliation
and before publishing query services. State is keyed by `dictionaryID`, so a drain or exclusive
operation for one dictionary does not serialize unrelated dictionaries. A ready descriptor still
must pass Catalog eligibility, then acquire a generation-bound query lease before its runtime or
SQLite index is accessed. Draining blocks new leases and waits only for existing leases; it never
holds the short Catalog mutation lock while waiting.

Removal acquires an exclusive permit, drains leases, invalidates the target runtime, stages and
commits the Catalog, then retires the generation. The R2 rule remains unchanged: a stage failure
resumes only after canonical identity exactly matches the original plan; uncertainty stays
suspended. A successful rollback publishes a new available generation; rollback uncertainty stays
suspended; deferred cleanup remains retired. Indexing uses the same exclusive permit for its whole
operation as a safety-first first version, so a ready runtime is never replaced while in use.

These leases coordinate only this App process. They are not an fd-bound SQLite identity guarantee
across processes; that boundary remains D1b-3B-3.
