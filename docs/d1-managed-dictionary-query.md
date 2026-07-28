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

Runtime cache identity is `(dictionaryID, generation)`. Removal or a successful index publication
increments generation after its drain; old cache entries are not used by a later lease. This is a
process-local safety boundary, not a cross-process SQLite file-identity guarantee. A Catalog
transition never clears a runtime while an old query lease is active; after the final lease for a
stale generation releases, only that `(dictionaryID, generation)` cache entry is evicted. fd-bound source
and index identity remain D1b-3B-3.

Lookup order is unchanged for existing dictionaries: preferred legacy sources first, then eligible
`managedLocal` descriptors. Only after that tier has no hits may an eligible app-managed
OpenResource fallback be queried. Same-tier results retain stable Catalog sort order. Before an
in-flight result returns, the query service first obtains the lifecycle snapshot, then—without a
further await—rechecks the current Catalog and generation. Disabled, removed, or transitioned
descriptors cannot publish stale results. Misses and runtime
errors are isolated and never auto-trigger AI. Both managed tiers use the existing generic MDict
sanitizer, so no raw HTML, scripts, external resources, receipt contents, or paths enter the display
result.
