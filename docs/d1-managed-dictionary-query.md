# Managed dictionary query coordination (D1b-3B-2C)

Managed dictionary runtime access is coordinated in-process by a single shared
`ManagedDictionaryLifecycleCoordinator`, keyed by `dictionaryID`. Each query obtains a lease
containing the dictionary UUID, a monotonic generation, and a unique lease UUID before opening or
using a cached runtime. Structured lease release covers normal return, errors, and cancellation.
An old generation cannot acquire a newly published runtime.

An install, index, removal, or reconciliation publication first obtains the dictionary's exclusive
permit. It stops new leases, waits for active leases to finish, invalidates the affected runtime,
does file work outside the Catalog lock, commits the short Catalog transaction, and then publishes
one explicit disposition: available, suspended, or retired. Queued exclusive operations are FIFO
per dictionary. Different dictionary IDs remain independent. Cancellation while waiting removes
the waiter; a completed mutation follows its explicit fail-closed disposition rather than an
unconditional resume.

Runtime cache identity is `(dictionaryID, generation)`. Removal or a successful index publication
increments generation after its drain; old cache entries are not used by a later lease. This is a
process-local safety boundary, not a cross-process SQLite file-identity guarantee; fd-bound source
and index identity remain D1b-3B-3.

Lookup order is unchanged for existing dictionaries: preferred legacy sources first, then eligible
`managedLocal` descriptors. Only after that tier has no hits may an eligible app-managed
OpenResource fallback be queried. Same-tier results retain stable Catalog sort order. Misses and
runtime errors are isolated and never auto-trigger AI. Both managed tiers use the existing generic
MDict sanitizer, so no raw HTML, scripts, external resources, receipt contents, or paths enter the
display result.
