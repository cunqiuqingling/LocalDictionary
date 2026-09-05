# 2026-09-06 AI / Apple / Obsidian regression audit

## Evidence and limits

The reported screenshots show a generic provider parameter rejection, not the raw HTTP error body. They do not establish which Gemini field was rejected or whether Zhipu's 429 arose from account-wide concurrency, rate limits, or an unfinished remote generation. No real API requests or Keychain secret reads were used for this repair. Mock transport tests verify the application contract; external service availability and semantic answer quality still require user acceptance testing.

Official references: [Gemini OpenAI compatibility](https://ai.google.dev/gemini-api/docs/openai), [Zhipu rate limits](https://docs.bigmodel.cn/cn/api/rate-limit), [Zhipu thinking mode](https://docs.bigmodel.cn/cn/guide/capabilities/thinking-mode).

## Before → after

| Area | Previous implementation | Repair |
| --- | --- | --- |
| Transport | Session request timeout 15 s / resource 30 s, request 30 s | Session 90 s / 180 s, connection request 60 s, production 90 s |
| Provider concurrency | Separate clients for separate actions, no shared provider gate | Shared host-level serialization across production clients; an active operation blocks a new connection test before HTTP |
| 429 / timeout | No cross-action cooldown | Honor Retry-After (seconds or HTTP date; default 60 s); wait 15 s after timeout, since remote work may continue; no immediate HTTP retry |
| Local wait vs HTTP failure | No local wait state | Local cooldown clearly says no new request was sent; never relabeled as a new HTTP 429 |
| Connection test | Optional production fields, universal 64-token budget | One minimal request; GLM keeps 64 and explicit thinking disabled; Gemini gets 2048 tokens of headroom without lowering its reasoning defaults |
| Optional-field rejection | Terminal HTTP 400 | At most one serial recovery only when HTTP 400 explicitly rejects a sent temperature/response_format field; remove only named fields |
| Model upgrades | DeepSeek names containing reasoner blocked for quick lookup; any 400 mentioning model could be labeled missing model | No local reasoner blacklist; only explicit missing-model errors get that label; user model ID sent unchanged |
| Apple English lookup | English words excluded from automatic short translation; an empty local result could retain loading text | Shared tested short-lookup policy includes both languages' words and phrases; fallback render and cancelled availability guard |
| Obsidian | No installation guard | Check md.obsidian dynamically on each favorite/note-picker action; requested missing-app message; user still explicitly chooses a note in their vault |
| Help | No distinction between connection success and full query availability | In-app bilingual FAQ describes cooldowns, model/account checks and cache limitations |

Cache inspection found that failed HTTP requests are not stored as successful answers. Clearing cache cannot repair an HTTP 400/429; repeated success after clearing does not prove cache corruption. This repair does not introduce a model capability cache that could become stale after renaming a model.

## GLM historical contract retained

All five paths use `https://open.bigmodel.cn/api/paas/v4/chat/completions`, Bearer authentication and real production JSON `thinking: { type: disabled }` (not merely a UI state). Budgets remain: connection 64, bilingual word 1800, deep translation 4000, sentence analysis 2600, inline quick word 512. No duplicated `/v1`. Visible `choices[0].message.content` is extracted; reasoning_content never becomes the visible answer. Thinking is preserved on optional-field and visible-content recovery.

## Quality boundary

No shortening of production input, prompts, answer budgets, parsing/translation validation or learning content was introduced. Production temperature stays unchanged unless that exact parameter is explicitly rejected. Gemini reasoning is not disabled or reduced. Connection testing is not a quality evaluation or a guarantee of subsequent quota/network availability. Future models must still implement a compatible text chat endpoint; an application cannot guarantee arbitrary future provider protocols.

## Regression coverage

- Existing five-path GLM body/endpoint/content fixtures and provider parsing/fallback/cache tests.
- New active-request exclusion, local cooldown vs HTTP 429, default/Retry-After delay tests.
- New future-model optional-parameter recovery with identical prompts, model and production budget.
- New Gemini connection headroom and unchanged thinking defaults check.
- New English/Chinese word and phrase Apple direction tests.
- New synthetic Obsidian absent → installed checks, plus existing isolated Markdown save/deduplication tests.
- Verified: `Tests/run-public-ci-smoke.sh` passed in an isolated home with real Keychain smoke disabled, including all public tests, release structural gates and unsigned packaging dry-run. Dedicated final AI, Apple direction and Obsidian smoke runs also passed. Publication additionally requires clean-commit community release verification and downloaded artifact checksum verification.

Local runtime data is reset only after backing up this app's exact state. Dictionaries, AI settings/cache/credentials must be absent in the fresh test environment; unrelated files and Obsidian vault contents are not reset. macOS-owned Apple language packs are retained.
