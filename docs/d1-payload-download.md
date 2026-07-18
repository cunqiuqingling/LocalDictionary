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

Payload chunks are written directly to an exclusive `O_NOFOLLOW` file descriptor;
they are never accumulated into one `Data` value. Each chunk is checked before the
write, fully written with partial-write and `EINTR` handling, and then fed into an
incremental CryptoKit SHA-256 state. The complete lowercase 64-character digest must
exactly match the signed digest.

The staging root is always injected and has no production Application Support
default. Directories use mode `0700` and the payload file uses `0600`:

```text
<injected-root>/.partial-<UUID>/<signed-name>.mdx.part
<injected-root>/verified-<UUID>/<signed-name>.mdx
```

After size and digest verification, the file is `fsync`ed and closed, renamed to the
signed name, the operation directory is `fsync`ed, the partial directory is atomically
renamed to its verified name, and the staging root is `fsync`ed. Cancellation and
failure close the descriptor and remove only the current partial operation. Existing
verified directories are never removed. A crash may leave a clearly named partial
directory; startup recovery is intentionally deferred to D1b-3B.

The injected root and each newly created operation directory are checked with
`lstat`, symlink resolution, and direct-parent containment before the payload file is
opened with `O_EXCL | O_NOFOLLOW`. Because this scoped implementation does not yet
use directory file descriptors with `openat`/`renameat`, an attacker who can mutate
the private `0700` staging root concurrently still represents a residual path-based
TOCTOU risk. D1b-3B must preserve or strengthen this boundary before production host
configuration is enabled.

The coordinator permits one operation at a time and emits progress containing only
an operation UUID, byte counts, and a phase. It never reports URLs, paths, Manifest
contents, or hashes. The verified staging result means only that transport limits,
exact size, and SHA-256 passed. It does not write the Catalog, build an index, enable
or query a dictionary, accept a license, or install the file. D1b-3B owns installation
and lifecycle integration. C++ Record resource limits remain a D1b-3A-2B prerequisite
before any real resource is opened.
