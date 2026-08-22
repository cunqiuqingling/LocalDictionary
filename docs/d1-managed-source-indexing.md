# Managed source capability during index construction

App-managed indexing retains the existing lifecycle and Catalog transaction
order: acquire the dictionary-keyed exclusive permit, reload the latest
durable descriptor, mark it indexing, invalidate the prior runtime
generation, perform file work, seal and validate the candidate SQLite
database, publish atomically, commit Catalog state, rebind the published
capability, and only then complete the lifecycle permit as available.

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

The index directory is also opened component by component beneath the
controlled root. Production creates one publication-scoped
`.dictionary.<publicationID>.candidate` as a `0600`, exclusive, no-follow
regular file and retains its writable descriptor and name/inode binding. The
SQLite builder receives the pathname only as SQLite's transport to that
already-created object. Before accepting the build, production proves that
the name still denotes the held inode and that no journal, WAL or SHM
auxiliary file exists.

Sealing fsyncs the candidate, changes it to `0400`, closes the writable
descriptor, reopens it read-only, and checks its SHA-256, SQLite integrity,
closed schema, actual entry count, and all persistent metadata. SQLite is
opened through `MDictCore/FDBoundSQLiteReadOnlyVFS`: its one-shot registry
token duplicates the held descriptor, reads with `pread`, and has no POSIX
pathname open, default-VFS fallback, `/dev/fd`, private SQLite `unixFile`, or
disk-path fallback. Writes, creation, auxiliary databases, journal, WAL, SHM
and mmap are rejected.

Publication uses `renameatx_np(RENAME_EXCL)` in the same directory to
`dictionary.<publicationID>.sqlite`, reopens and rebinds the final name, and
fsyncs the file and directory. Catalog v3 commits the publication ID, index
digest/size, source digest/size, schema, entry count and exact versioned
relative path. A final capability rebind after that Catalog transaction is
required before the lifecycle becomes available. A failure before Catalog
commit removes only an object still proven to be the held capability; an
identity mismatch or durability uncertainty preserves the object rather than
guessing by pathname.

Cancellation, digest/size mismatch, parser failure, build failure, SQLite
metadata mismatch, auxiliary-file creation, no-replace conflict, or any
post-open replacement cannot mark Catalog ready or complete the lifecycle as
available. A post-Catalog rebind failure attempts a guarded Catalog downgrade
to `pendingIndex`; if either filesystem or Catalog identity is uncertain, the
runtime stays suspended.

This boundary detects ordinary modification, rename/replacement, same-size
different-content substitution, symlink substitution, and managed ancestor
replacement. It does not claim protection against an arbitrary malicious
same-UID process continuously modifying an already-open inode. The VFS's
whole-file shared `fcntl` lock is an additional prototype-derived constraint;
it is not equivalent to SQLite's default Unix VFS byte-range locking and is
not the basis of the identity proof.
