# D1b-2B verified payload staging

D1b-2B adds an isolated transport for one signed resource payload. It supports only
`mirroredDownload`, `archiveFormat=none`, `dictionaryFormat=generic-mdict-v1`, and a
single MDX file. It does not support ZIP extraction, MDD resources, resume data, or
background downloads.

The download plan is derived from an already verified Manifest resource. Its signed
`allowedDownloadHosts` are intersected with an application-supplied host allowlist,
and the initial URL, every redirect, and the final response URL must remain inside
that exact-host intersection. The production application allowlist is empty, so the
feature remains disabled. Tests use only synthetic `example.test` URLs through
`URLProtocol`.

The request is an ephemeral, cookie-free, cache-free HTTPS GET. It sends
`Accept-Encoding: identity`, accepts only HTTP 200 and
`application/octet-stream`, and does not use authorization headers. Redirects retain
the audited D1b-2A HTTPS and exact-host policy and are limited to five hops.

All core size values are `UInt64`. The application hard limit is 512 MiB, while the
effective resource limit is bounded by the signed `maximumDownloadedSize`. Manifest
v1 also provides signed `compressedSize`; therefore a present `Content-Length` and
the final received byte count must both equal that exact value. Disk capacity is
checked before creating the payload file, with a default 64 MiB safety margin, while
write failures such as `ENOSPC` remain authoritative.

Payload chunks are written directly to an exclusive `O_NOFOLLOW | O_CLOEXEC` file
descriptor; they are never accumulated into one `Data` value. The staging operation
is the single authority for successful written-byte accounting and incremental
CryptoKit SHA-256. Each chunk is checked before the write, fully written with
partial-write and `EINTR` handling, and only then contributes to the digest.

The staging root is always injected and has no production Application Support
default. Directories use mode `0700` and the payload file uses `0600`:

```text
<injected-root>/.partial-<UUID>/payload.mdx.part
<injected-root>/verified-<UUID>/payload.mdx
```

The injected root is the sole absolute-path boundary. It is opened once with
`O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC`, then every descendant operation uses a
validated single component with `mkdirat`, `openat`, `fstatat`, `renameat`, or
`unlinkat`. The root and operation directory are owner-owned, non-symlink directories
without group/other write permission; the payload is a `0600`, owner-owned regular
file with link count one.

Before publication, the writer checks exact size and SHA-256, `fstat`s and `fsync`s
the still-open payload fd, and compares its identity with the `fstatat` partial entry.
It then renames the file within the operation directory, verifies the final entry is
the same inode, `fsync`s that directory, renames the whole operation directory under
the root fd, verifies its inode again, and finally `fsync`s the root fd. Thus the inode
streamed, bounded, hashed, and fsynced is the inode atomically published. Failure or
cancellation uses `unlinkat` only for known leaf components and never recursively
deletes unknown entries. A crash may still leave a clearly named partial or verified
directory; startup orphan recovery is intentionally deferred to D1b-3B-2.

The capability boundary prevents descendant path traversal, symlink following, and
ordinary path substitution. It does not claim to isolate an arbitrary malicious
process running as the same Unix UID, which can mutate any directory that user owns.
All tests use synthetic payloads and isolated temporary roots. Production payload hosts
remain empty, and this stage neither creates Catalog/open-resource records nor installs
or indexes a payload.

The coordinator permits one operation at a time and emits progress containing only
an operation UUID, byte counts, and a phase. It never reports URLs, paths, Manifest
contents, or hashes. The verified staging result means only that transport limits,
exact size, and SHA-256 passed. It does not write the Catalog, build an index, enable
or query a dictionary, accept a license, or install the file. D1b-3B owns installation
and lifecycle integration. C++ Record resource limits remain a D1b-3A-2B prerequisite
before any real resource is opened.
