# D1 MDict Resource Metrics Probe

## Why formal limits need measurement

The D1b-3A security audit revealed that the mdict-cpp parser has no
upper bounds on any allocation driven by file metadata (header size,
key-block info size, key-block compressed/decompressed size, record-block
counts, etc.).  A maliciously crafted `.mdx` file can trigger
multi-gigabyte allocations before the App ever reaches the 512 KiB HTML
truncation in Swift.

Before we can set safe, non-breaking `ResourceLimits`, we must know what
legitimate values our existing dictionaries actually produce.  This tool
collects those values anonymously.

## What this tool is

- A **test/development command-line tool**, never shipped to users.
- Reads only **metadata** — `initMetadataOnly()`.
- Never materialises key lists, never decompresses record content,
  never builds an SQLite index, never invokes the formatter.
- Output is a single JSON object with **anonymous IDs and numbers only**.

## What this tool is NOT

- Not part of the App target.
- Not included in the App Bundle.
- Not a replacement for the D1b-3A `ResourceLimits` implementation.
- Not a security fix for any parsing vulnerability.
- Not suitable for untrusted MDX files (it has the same attack surface
  as `initMetadataOnly()` — it is built for the Owner's trusted
  dictionaries).

## Data collected (per dictionary)

| Field | Source |
|-------|--------|
| `actualFileBytes` | `stat()` |
| `headerBytes` | `header_bytes_size` from file |
| `keyBlockInfoCompressedBytes` | `key_block_info_size` |
| `keyBlockInfoDecompressedBytes` | `key_block_info_decompress_size` |
| `keyBlockCount` | `key_block_num` |
| `entryCount` | `entries_num` |
| `maximumSingleKeyBlockCompressedBytes` | max over `key_block_info_list` |
| `maximumSingleKeyBlockDecompressedBytes` | max over `key_block_info_list` |
| `totalKeyBlockCompressedBytes` | `key_block_size` (header field) |
| `totalKeyBlockDecompressedBytes` | sum over `key_block_info_list` |
| `recordBlockInfoBytes` | `record_block_header_size` |
| `recordBlockCount` | `record_block_number` |
| `maximumSingleRecordBlockCompressedBytes` | max over `record_header` |
| `maximumSingleRecordBlockDecompressedBytes` | max over `record_header` |
| `totalRecordBlockCompressedBytes` | `record_block_size` |
| `totalRecordBlockDecompressedBytes` | `recordStreamSize()` |
| `encryptedMode` | 0=none, 1=record, 2=key-info |
| `engineVersionMajor` / `engineVersionMinor` | parsed from header XML |

## Fields marked unavailable

| Field | Reason |
|-------|--------|
| `maximumSingleKeyBytes` | Requires parsing full key blocks (materialises all keys) |
| `maximumObservedRecordRangeBytes` | Requires entry-level record parsing |

Both appear in the JSON as string arrays under their field names so the
consumer can distinguish "0" (a real value) from "unavailable".

## Encrypted=2 support

The probe reuses the existing RIPEMD/key-info decryption path that is
already exercised by `initMetadataOnly()`.  No new crypto code is added.
If the decryption path fails the tool reports `encryptedMetadataUnsupported`.

## Privacy

- No file path, basename, or directory appears in the output.
- No key text, record content, or header XML appears in the output.
- No SHA checksums, no inode numbers, no user-identifying data.
- Output file permissions are set to `0600`.

## Manual run procedure (for the project Owner only)

1. Quit Claude Code.
2. Open a plain Terminal window.
3. `cd /path/to/LocalDictionary-d1b3a-deepseek`
4. Build: `Tests/run-mdict-resource-metrics-probe-smoke.sh`
5. Run:
   ```
   Tests/run-mdict-resource-metrics-probe.sh \
     --dictionary D1 "/private/path/to/dict1.mdx" \
     --dictionary D2 "/private/path/to/dict2.mdx" \
     --output /tmp/localdictionary-mdict-metrics.json
   ```
6. Verify `ls -la /tmp/localdictionary-mdict-metrics.json` shows `-rw-------`.
7. Inspect the JSON — confirm no paths, filenames, or content.
8. Share only the numeric JSON; never share the `.mdx` files.

## Not a security fix

This tool does **not** add any bounds checking to the mdict-cpp parser.
The D1b-3A audit findings remain open.  After the Owner collects real
metrics from their five preferred dictionaries, those numbers will
inform the `ResourceLimits` constants in a future D1b-3A implementation
phase.
