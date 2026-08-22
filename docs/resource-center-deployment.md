# Resource Center deployment inputs

Production remote catalog support remains disabled until all inputs below receive an independent
license and security review and are injected together through
`ResourceCenterProductionConfiguration.current`.

Required deployment inputs:

1. Canonical HTTPS manifest URL and detached-signature URL.
2. Exact DNS host allowlist for both URLs.
3. Exact application payload-host allowlist.
4. One or more reviewed Ed25519 public keys and stable key IDs.
5. A monotonically increasing signed manifest version.
6. Per-resource publisher/source evidence, license text or URL, explicit redistribution and
   mirroring permission, payload byte size, SHA-256, stable resource ID, increasing resource
   revision, and supported `generic-mdict-v1` metadata.
7. Hosting retention sufficient for clients already using a signed manifest.

The example in `docs/templates/resource-manifest-v1.empty.json` intentionally contains no resource,
URL, payload, or usable signing material.

## Hosting layout example

A static HTTPS host (including a reviewed GitHub Pages or Releases arrangement) may expose two
immutable objects, such as a manifest JSON and its binary `LDMSIG01` envelope. Payload objects may
be on separate exact allowlisted hosts. Deployment must not redirect to a different host, serve
compressed HTTP content, mutate an existing manifest version, or replace a resource revision with
a different digest.

No repository command in M23 uploads these objects, creates a Release, or configures GitHub.

## Signing and rotation

Keep private keys outside the repository, App bundle, test fixtures, logs, and CI artifacts.
Sign the exact manifest bytes; changing whitespace after signing invalidates the signature. The
binary envelope format and limits are documented in `docs/d1-manifest-format.md`.

For rotation, ship the new public key in a reviewed App version before using its key ID. Publish a
higher manifest version signed by the new key. Never insert test keys into production trust and
never select keys through an environment variable or a user-entered URL.

## Resource admission checklist

- [ ] Stable publisher and source project are identified.
- [ ] License evidence is archived and its digest reviewed.
- [ ] Redistribution and mirroring are explicitly permitted.
- [ ] Commercial or copyright-unclear content is excluded.
- [ ] Payload is a single uncompressed MDX with no MDD/media.
- [ ] Payload source, byte size, SHA-256, version, and revision are reproducible.
- [ ] Manifest and payload hosts are exact HTTPS DNS names.
- [ ] `generic-mdict-v1` output passes formatter security fixtures.
- [ ] Update preserves the old version until the new sealed index is ready.
- [ ] Removal inventory can prove every object before deletion.
