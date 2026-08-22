# Managed dictionary query coordination (D1b-3B-2C)

Managed dictionary runtime access is coordinated in-process by a single shared
`ManagedDictionaryLifecycleCoordinator`, keyed by `dictionaryID`. Each query obtains a lease
containing the dictionary UUID, a monotonic generation, and a unique lease UUID before opening or
using a cached runtime. The coordinator records each active lease by UUID and generation, so
structured release covers normal return, errors, cancellation, and a pending generation
transition. An old generation cannot acquire a newly published runtime, but an already-issued old
lease can still release safely.

An identity-changing Catalog update becomes a pending transition: it stops new leases, drains the
old generation, then advances generation exactly once. While draining, the pending target is
latest-wins: a later identity update replaces the unpublished target, deletion replaces it with
retirement, and a disabled or otherwise ineligible descriptor replaces it with suspension. An install, index, removal, or
reconciliation publication first obtains the dictionary's exclusive permit. Indexing publishes
`.indexing` only after that permit is held. File work stays outside the Catalog lock, then a short
Catalog transaction and one explicit disposition publish available, suspended, or retired. Queued
exclusive operations are FIFO per dictionary; cancellation removes a waiter and shutdown resumes
all queued waiters with a fixed error. Different dictionary IDs remain independent.

Runtime cache identity is `(dictionaryID, generation, indexPublicationID,
indexSHA256)`. Removal or a successful index publication increments generation
after its drain; a later publication cannot reuse an old runtime even if other
descriptor fields happen to match. A Catalog transition never clears a runtime
while an old query lease is active; after the final lease for a stale
generation releases, only that exact cache entry is evicted.

An app-managed runtime opens the source and versioned final index from the
controlled root with component-by-component, no-follow descriptor
capabilities. Source size/SHA and ancestor/name binding must match Catalog v3.
The index must be a `0400`, single-link regular file whose size/SHA, publication
ID, dictionary ID, source identity, schema and actual entry count all match the
same Catalog identity. SQLite opens the index only through the production
fd-bound read-only VFS; no managed query path calls the default SQLite VFS or
falls back to a disk pathname. The bridge retains both capabilities for the
runtime lifetime and rechecks their descriptor and name bindings on every
lookup, including cache hits.

An identity mismatch is a typed fail-closed result. After the current lease is
released, query coordination evicts the affected runtimes and publishes a
suspended generation before final batch validation. It never returns the
possibly stale lookup and never repairs Catalog while holding a query lease.

Lookup order is unchanged for existing dictionaries: preferred legacy sources first, then eligible
`managedLocal` descriptors. Only after that tier has no hits may an eligible app-managed
OpenResource fallback be queried. Same-tier results retain stable Catalog sort order. Before an
in-flight result becomes a candidate, the coordinator atomically releases its lease and reports the
drained generation plus post-release lifecycle state. Necessary generation-scoped eviction for
every candidate happens before one coherent batch lifecycle snapshot. That batch snapshot is the
public lookup's last await. The query actor then synchronously compares every immutable candidate
with its current Catalog descriptor, lifecycle generation, and canonical runtime-affecting
identity, forms the final ordered result array, and returns without another suspension. A prior
candidate disabled, deleted, or identity-replaced while a later dictionary is awaiting cannot
publish. A writer that is merely queued may allow an already-started query only when generation
and runtime identity remain unchanged. The generation-scoped runtime removal operation has no
dictionary-wide protocol default; every runtime explicitly implements it. Misses and runtime
errors are isolated and never auto-trigger AI. Both managed tiers use the existing generic MDict
sanitizer, so no raw HTML, scripts, external resources, receipt contents, or paths enter the display
result.

The production VFS keeps mmap disabled and rejects write, create, auxiliary
database, journal, WAL and SHM operations. Its whole-file shared `fcntl` lock
is not equivalent to the default Unix VFS byte-range locking protocol. The
design does not claim to defeat an arbitrary malicious same-UID process that
continually writes an already-open inode.
