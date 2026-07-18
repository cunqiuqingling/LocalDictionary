# D1 Manifest network fetch boundary

D1b-2A adds a dedicated transport for fetching only the detached signature sidecar
and the signed Manifest. It does not download dictionary payloads, stage files,
verify payload SHA-256 values, modify the Catalog, build indexes, or add UI. The
production endpoint and production host allowlist remain disabled, and the
production Manifest trust store remains empty.

## Request order and session isolation

One refresh validates its injected endpoint, fetches the signature first, fetches
the Manifest second, and passes both original byte sequences to the existing
D1b-1 verifier. It returns `PreparedManifestVerification`; it does not call the
rollback state commit API or persist a Manifest cache.

Every fetch uses a dedicated ephemeral `URLSession` with no URL cache, cookie
storage, credential storage, background identifier, or connectivity waiting.
Requests are bodyless `GET` operations, use `Accept-Encoding: identity`, and do
not add Authorization or Cookie headers. System TLS verification is unchanged;
there is no ATS exception or custom trust challenge handling.

## URL and redirect policy

Initial URLs, every redirect target, and the final response URL must use HTTPS on
the default port and match an App-injected exact-host allowlist. Hosts are compared
as lowercase ASCII. Valid punycode is supported; direct Unicode hosts, IP literals,
localhost or other single-label names, trailing dots, user information, fragments,
non-default ports, and suffix lookalikes are rejected.

Only status 301, 302, 307, and 308 redirects are considered, with at most five
hops. Each hop must remain a bodyless GET and pass the same URL policy. Redirect
loops and HTTPS downgrades fail closed. The remote Manifest cannot add trusted
hosts.

## Bounded streaming responses

Only HTTP 200 final responses are accepted. Signature content type is limited to
`application/octet-stream`; Manifest content type is limited to
`application/json` or `application/octet-stream`. Any non-identity content encoding
is rejected.

The signature limit is the smaller of the verifier policy and 4 KiB. The Manifest
limit is `ManifestVerificationPolicy.maximumManifestBytes` (1 MiB by default).
`Content-Length` above a limit is rejected before accepting body bytes. Missing or
incorrectly small lengths do not weaken the limit: every incoming chunk is checked
for integer overflow and total size before append. An over-limit response cancels
the URL session task and discards its buffer.

Swift task cancellation propagates to the active URL session task. Cancellation
does not call the verifier and is reported separately from transport failure. A
loader actor allows only one refresh operation at a time; a concurrent refresh is
rejected rather than sharing a mutable buffer.

## Verification handoff and future stages

The transport does not decode or normalize Manifest bytes. The existing Ed25519
verifier receives the signature envelope and Manifest exactly as fetched, then
performs strict JSON, semantic, expiry, key, and rollback validation. Synthetic
tests use `example.test`, runtime-generated TEST-ONLY keys, and an injected
`URLProtocol`; no test accesses DNS, the internet, Keychain, real Application
Support, or dictionary data.

D1b-2B will separately address resource payload staging and payload SHA-256
verification. Resource installation, MDict parsing, and the existing C++ MDict
resource-allocation P1 boundary are not changed by D1b-2A.
