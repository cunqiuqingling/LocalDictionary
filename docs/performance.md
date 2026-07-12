# Performance

No application-level performance claim is made before the native app exists. Phase 1 measures the parser probe to expose initialization and lookup costs that influence the production index design.

Targets remain: idle CPU near 0%, idle RSS preferably below 60 MB, common lookup near 100 ms, bounded caches, and no directory polling or high-frequency logging.

## Phase 1 measurements (Apple M2, 8 GB, arm64 release probe)

Five warm-filesystem Oxford runs, each initializing the 20 MiB MDX and querying the same ten words:

| Measurement | Observed |
|---|---:|
| Parser initialization | 12.221–16.379 ms |
| RSS immediately after initialization | 11.80–12.48 MiB |
| RSS after ten lookups | 13.95–14.81 MiB |
| Whole process wall time for one 10-word run | 0.28 s |
| CPU time for that run | 0.27 s user, 0.00 s system |

Individual Oxford lookup times in the recorded compatibility run were 1.303–14.169 ms. The largest tested entry was `run` at 100,975 bytes.

Additional observed initialization points:

- Longman MDX (195 MiB): 39–74 ms in recorded runs; about 21.5–23.0 MiB RSS after initialization. Following the three problematic large aliases raised end-of-run RSS to about 76 MiB, confirming they must not be retained.
- Longman MDD (1.2 GiB): 167–190 ms initialization and about 26.7 MiB RSS; individual tested MP3 reads were approximately 1–3 ms.
- Oxford MDD (316 MiB): 68–95 ms initialization and about 13.2–13.6 MiB RSS; tested resource reads were generally below 3 ms after initialization.

These are parser-process measurements with a warm filesystem cache, not application startup or idle measurements. The app, panel, WebKit, Accessibility, idle CPU, memory reclamation, and disk-write tests remain pending later phases. No idle or disk-write claim is made now.

## Phase 2 SQLite core measurements

Dictionary: selected Oxford Advanced Learner's 8 bilingual MDX, 21,452,297 bytes. Index and query executable were built as optimized arm64 code. Disk counters come from macOS `proc_pid_rusage(RUSAGE_INFO_V4)`; peak RSS comes from `getrusage`.

### First build

| Measurement | Observed |
|---|---:|
| Indexed rows | 109,473 |
| SQLite index size | 8,884,224 bytes (8.47 MiB) |
| First index build | 163.033 ms |
| Build plus read-only reopen | 163.834 ms |
| Peak RSS during build and 20 lookups | 27,246,592 bytes (25.98 MiB) |
| Disk writes | 8,957,952 bytes |
| 20-word success | 19/20 (95%) |
| Mean lookup immediately after build | 0.582 ms |
| Slowest immediately after build | 3.865 ms (`prodigality`) |

The generated index accounts for essentially all writes. It is built as a temporary SQLite file and renamed only after completion; original dictionary files remain read-only.

### Reused index

Five unchanged-source launches confirmed `rebuilt=false` and zero disk writes.

| Measurement | Observed |
|---|---:|
| Warm startup after filesystem cache is populated | 1.524–1.703 ms |
| First colder reused-index startup in the five-run sample | 9.872 ms |
| Warm mean query across the 20-word set | 0.147–0.153 ms |
| Warm slowest query | 0.293–0.312 ms (`run`) |
| Colder run mean / slowest | 0.654 / 1.229 ms |
| Reused-process peak RSS | 7.50–8.47 MiB |
| Disk writes | 0 bytes |

The OS may satisfy later reads from its filesystem cache, so disk-read counters can be zero on warm runs; this is not interpreted as the application performing no logical reads. The important write result is consistently zero after index creation.

### Bounded cache

The core caches complete returned records with two simultaneous limits: 64 entries and 8 MiB. Oversized records are not cached; least-recently-used records are evicted until both limits are satisfied. The 20-word test retained 19 records totaling 321,761 bytes.

These numbers still exclude AppKit, Accessibility and WebKit because phase 3 has not started.
