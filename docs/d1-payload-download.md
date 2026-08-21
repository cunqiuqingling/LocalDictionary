# D1b-2B verified payload staging

D1b-2B adds an isolated transport for one verified resource payload. The remote-manifest path supports only
`mirroredDownload`, `archiveFormat=none`, `dictionaryFormat=generic-mdict-v1`, and a
single MDX file. It does not support ZIP extraction, MDD resources, resume data, or
background downloads.

The download plan is derived from an already verified Manifest resource. Its signed
`allowedDownloadHosts` are intersected with an application-supplied host allowlist,
and the initial URL, every redirect, and the final response URL must remain inside
that exact-host intersection. The production application allowlist contains only
`download.freedict.org` for the immutable bundled starter; the remote manifest endpoint and trust
store remain disabled. Tests use only synthetic `example.test` URLs through `URLProtocol`.

The request is an ephemeral, cookie-free, cache-free HTTPS GET. It sends
`Accept-Encoding: identity`, accepts only HTTP 200 and
`application/octet-stream`; the typed FreeDict XZ starter additionally accepts only
`application/x-xz`. It does not use authorization headers. Redirects retain
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

The injected root is the sole absolute-path boundary for descendant mutations. It is
opened with `O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC`, then every descendant operation
uses a validated single component with `mkdirat`, `openat`, `fstatat`,
`renameatx_np(..., RENAME_EXCL)`, or `unlinkat`. The root and operation directory are
owner-owned, non-symlink directories without group/other write permission; the
payload is revalidated as a `0600`, owner-owned regular file with link count one
before publication. The capacity preflight currently queries the injected root URL;
moving that read to an fd-bound API remains deferred hardening work.

Before publication, the writer checks exact size and SHA-256, `fstat`s and `fsync`s
the still-open payload fd, and compares its identity with the `fstatat` partial entry.
Both the inner payload publication and outer directory publication use
`renameatx_np(..., RENAME_EXCL)`: an existing target is atomically rejected and is
never overwritten. The final payload and verified directory are identity-checked after
each rename. After the outer rename has succeeded and its identity check has passed,
the operation enters a durability-unconfirmed state before `fsync` of the root fd.
If that final `fsync` fails, the API returns a durability failure but preserves the
verified directory and payload for deferred D1b-3B-2 reconciliation; it is not
reported as a successful publication and cleanup does not delete it. Before that
irreversible outer rename, failure or cancellation uses `unlinkat` only for known leaf
components and never recursively deletes unknown entries. A crash may still leave a
clearly named partial or verified directory; startup orphan recovery is intentionally
deferred to D1b-3B-2.

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

## D1b-3B-2A-R1 installation boundary

Before an open-resource directory can leave verified staging, its receipt is read again from the
still-open sidecar descriptor with a bounded `pread` loop and is strictly matched to the immutable
installation identity. The source directory name is rebound to the opened verified descriptor
immediately before `renameatx_np(RENAME_EXCL)`. After the rename and parent-directory durability
step, the final directory, payload hash, receipt identity, and exact two-entry layout are checked
again before any Catalog mutation. A failed post-publication check preserves the final object and
does not write a descriptor; reconciliation remains deferred to D1b-3B-2B.
