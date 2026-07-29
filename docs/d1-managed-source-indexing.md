# Managed source capability during index construction

App-managed indexing retains the existing lifecycle and Catalog transaction
order: acquire the dictionary-keyed exclusive permit, reload the latest
durable descriptor, mark it indexing, invalidate the prior runtime
generation, perform file work, validate the candidate SQLite database,
publish atomically, commit Catalog state, and complete the lifecycle permit.
The Catalog schema, candidate publication protocol, and query runtime are not
changed here.

The indexing plan now carries the controlled Application Support root and the
Catalog-relative managed source component path separately. The worker opens a
single production source capability after the plan is derived. Starting from
the managed root directory descriptor, `MDictCore/ManagedMDictSource` walks
each relative component with `openat`, `O_NOFOLLOW`, `O_CLOEXEC`, and
read-only access. It rejects traversal, symlinks, non-directories,
non-regular final objects, owner mismatch, and a final source whose link
count is not one. The capability retains device/inode/type/owner identity,
size and modification time, plus descriptor-backed bindings for every
managed ancestor and the canonical source name.

SHA-256 is computed in bounded `pread` chunks on the capability's source
descriptor with cooperative cancellation. Descriptor identity is checked
before and after hashing, and the digest and size must match the latest
Catalog plan. The Objective-C++ bridge retains that same capability and
passes its borrowed descriptor to
`SQLiteDictionaryCore::buildIndexFromFileDescriptor`. The vendored parser
creates its own `F_DUPFD_CLOEXEC` duplicate; neither the bridge nor the
managed build reconstructs or reopens a source pathname. SQLite source
metadata is supplied from the capability identity and records only the
canonical source component as its non-authoritative source identifier.

After build returns, the worker verifies descriptor stability and the full
ancestor/name binding before candidate SQLite validation and again before
returning a prepared result. The prepared result retains the capability, and
the coordinator performs a final validation immediately before the existing
publication flow. Cancellation, digest/size mismatch, parser failure, build
failure, or any post-open replacement removes candidate artifacts and cannot
mark Catalog ready or complete the lifecycle as available.

This boundary detects ordinary modification, rename/replacement, same-size
different-content substitution, symlink substitution, and managed ancestor
replacement. It does not claim protection against an arbitrary malicious
same-UID process continuously modifying an already-open inode. Candidate
SQLite identity, final-index publication identity, managed query SQLite VFS
identity, persistent runtime-cache identity, and Catalog migration remain
separate unresolved work.
