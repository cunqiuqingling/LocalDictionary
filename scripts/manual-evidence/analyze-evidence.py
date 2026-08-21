#!/usr/bin/env python3
"""Analyze LocalDictionary opt-in JSONL evidence without reading product/user data."""

from __future__ import annotations

import argparse
import json
import sys
from collections import defaultdict
from pathlib import Path


RULES = [
    "APPLE-001", "APPLE-002", "APPLE-003", "APPLE-004", "APPLE-005",
    "APPLE-006", "APPLE-007", "APPLE-008", "APPLE-009", "APPLE-010",
    "FREE-001", "FREE-002", "FREE-003",
    "FREE-004", "FREE-005", "AI-001", "AI-002", "AI-003",
    "AI-004", "AI-005", "AI-006", "AI-007", "AI-008", "AI-009", "AI-010",
    "INLINE-001", "INLINE-002", "INLINE-003", "INLINE-004", "INLINE-005",
    "INLINE-006",
    "LANG-001", "LANG-002", "LANG-003", "LANG-004", "LANG-005",
    "LANG-006", "LANG-007", "LANG-008", "LANG-009", "LANG-010", "LANG-011",
]
FORBIDDEN_KEYS = {
    "query", "querytext", "sourcetext", "responsetext", "responsebody",
    "dictionarydefinition", "definitiontext", "apikey", "secret",
    "keychain", "obsidianbody", "privatepath",
}


def load_events(path: Path):
    events = []
    parse_errors = []
    with path.open("r", encoding="utf-8") as handle:
        for number, raw in enumerate(handle, 1):
            if not raw.strip():
                continue
            try:
                value = json.loads(raw)
                if not isinstance(value, dict):
                    raise ValueError("JSON value is not an object")
                events.append((number, value))
            except Exception as error:  # report line only, never echo content
                parse_errors.append((number, type(error).__name__))
    return events, parse_errors


def lines(values):
    return ", ".join(str(value) for value in sorted(set(values))) or "—"


def result(status, message, evidence=None):
    return status, message, list(evidence or [])


def relevant(events, event_type):
    return [(line, event) for line, event in events if event.get("eventType") == event_type]


def analyze(events, parse_errors):
    findings = {}
    privacy_lines = []
    for line, event in events:
        lowered = {str(key).lower() for key in event}
        if lowered & FORBIDDEN_KEYS:
            privacy_lines.append(line)
    if parse_errors or privacy_lines:
        evidence = [line for line, _ in parse_errors] + privacy_lines
        findings["EVIDENCE-SAFETY"] = result(
            "FAIL", "JSONL 无法完整解析，或包含禁止的正文/secret 字段。", evidence
        )
    else:
        findings["EVIDENCE-SAFETY"] = result(
            "PASS", "JSONL 可逐行解析，未发现禁止的正文/secret 字段。"
        )

    successes = relevant(events, "translationSucceeded")
    apple001 = []
    for success_line, success in successes:
        session = success.get("processSessionID")
        previous_operation = success.get("operationID")
        next_request = next(((line, event) for line, event in events
                             if line > success_line and
                             event.get("processSessionID") == session and
                             event.get("eventType") in {
                                 "appleTranslationRequested", "operationQueued"
                             } and event.get("operationID") and
                             event.get("operationID") != previous_operation), None)
        if not next_request:
            continue
        request_line, request = next_request
        operation = request.get("operationID")
        pair = (request.get("translationSourceLanguage") or request.get("queryLanguage"),
                request.get("translationTargetLanguage") or request.get("targetLanguage"))
        operation_events = []
        for line, event in events:
            if line < request_line or event.get("processSessionID") != session or \
                    event.get("operationID") != operation:
                continue
            event_pair = (event.get("translationSourceLanguage") or
                          event.get("queryLanguage"),
                          event.get("translationTargetLanguage") or
                          event.get("targetLanguage"))
            if all(pair) and all(event_pair) and event_pair != pair:
                continue
            operation_events.append((line, event))
        started = [(line, event) for line, event in operation_events
                   if event.get("eventType") == "nextOperationStarted"]
        terminal = [(line, event) for line, event in operation_events
                    if event.get("eventType") == "operationTerminal"]
        if not started:
            apple001.extend([success_line, request_line])
        elif terminal and terminal[-1][1].get("resultKind") not in {"success", "partialSuccess"}:
            apple001.extend([success_line, started[0][0], terminal[-1][0]])
    findings["APPLE-001"] = result(
        "FAIL" if apple001 else ("PASS" if successes else "WARNING"),
        "成功后的下一同语言对 operation 未进入执行或最终失败。" if apple001
        else ("success 后的下一 operation 已按 operationID/language pair 正常执行。" if successes
              else "未观察到真实 Apple translationSucceeded，无法判断。"),
        apple001,
    )

    apple002 = [line for line, event in events
                if event.get("systemAvailability") == "installed" and
                (str(event.get("serviceHealth", "")).lower() in {"unavailable", "failed"} or
                 "不可用" in str(event.get("statusPresented", "")))]
    findings["APPLE-002"] = result(
        "FAIL" if apple002 else "PASS",
        "installed 被 UI/service 标成 unavailable。" if apple002
        else "未发现 installed 与 unavailable 混淆。", apple002
    )

    terminal_sessions = {}
    reused = []
    for line, event in events:
        session = event.get("sessionGeneration")
        process = event.get("processSessionID")
        if event.get("eventType") == "operationTerminal" and session is not None:
            terminal_sessions[(process, session)] = line
        if event.get("eventType") == "nextOperationStarted" and session is not None:
            old = terminal_sessions.get((process, session))
            if old is not None:
                reused.extend([old, line])
    findings["APPLE-003"] = result(
        "FAIL" if reused else "PASS",
        "terminal sessionGeneration 被新 operation 复用。" if reused
        else "未发现 terminal sessionGeneration 复用。", reused
    )

    apple004 = [line for line, event in relevant(events, "successCleanupCompleted")
                if int(event.get("activeOperationCount", 0) or 0) != 0]
    findings["APPLE-004"] = result(
        "FAIL" if apple004 else "PASS",
        "success cleanup 后 activeOperationCount 非零。" if apple004
        else "success cleanup 后 active operation 已归零。", apple004
    )

    apple005 = []
    for index, (line, event) in enumerate(events):
        if event.get("eventType") != "successCleanupCompleted":
            continue
        pending = max(int(event.get("pendingTaskCount", 0) or 0),
                      int(event.get("pendingContinuationCount", 0) or 0))
        if pending <= 0:
            continue
        future = events[index + 1:index + 8]
        if not any(item.get("eventType") == "nextOperationStarted" for _, item in future):
            apple005.append(line)
    findings["APPLE-005"] = result(
        "FAIL" if apple005 else "PASS",
        "success 后 task/continuation 遗留且未被下一 operation 消费。" if apple005
        else "未发现跨 operation 的 task/continuation 遗留。", apple005
    )

    apple006 = [line for line, event in events
                if (event.get("eventType") == "lateCallbackDiscarded" and
                    event.get("callbackAccepted") is not False) or
                (event.get("eventType") == "lateCallbackAccepted")]
    findings["APPLE-006"] = result(
        "FAIL" if apple006 else "PASS",
        "late callback 被接受并可能污染新 operation。" if apple006
        else "未发现 late callback 写入新 operation。", apple006
    )

    apple007 = [line for line, event in relevant(events, "operationTerminal")
                if event.get("isChecking") or event.get("isPreparing") or
                event.get("isTranslating")]
    findings["APPLE-007"] = result(
        "FAIL" if apple007 else "PASS",
        "terminal operation 仍保留 checking/preparing/translating 标志。" if apple007
        else "terminal operation 的活动标志均已归零。", apple007
    )

    queued_never_started = []
    missing_terminal = []
    generation_jump = []
    for queued_line, queued in relevant(events, "operationQueued"):
        operation = queued.get("operationID")
        session = queued.get("processSessionID")
        if not operation:
            continue
        later = [(line, event) for line, event in events
                 if line > queued_line and event.get("processSessionID") == session]
        started = [(line, event) for line, event in later
                   if event.get("eventType") == "nextOperationStarted" and
                   event.get("operationID") == operation]
        terminal = [(line, event) for line, event in later
                    if event.get("eventType") == "operationTerminal" and
                    event.get("operationID") == operation]
        deadline = next(((line, event) for line, event in later
                         if (event.get("eventType") == "sessionRebuilt" and
                             "deadlineExceeded" in str(event.get("typedReason", ""))) or
                            (event.get("eventType") == "translationTimedOut")), None)
        if not started and not terminal and deadline:
            queued_never_started.extend([queued_line, deadline[0]])

    for started_line, started in relevant(events, "translationStarted"):
        operation = started.get("operationID")
        session = started.get("processSessionID")
        later = [(line, event) for line, event in events
                 if line > started_line and event.get("processSessionID") == session]
        terminal = next(((line, event) for line, event in later
                         if event.get("eventType") == "operationTerminal" and
                         event.get("operationID") == operation), None)
        deadline = next(((line, event) for line, event in later
                         if (event.get("eventType") == "sessionRebuilt" and
                             "deadlineExceeded" in str(event.get("typedReason", ""))) or
                            (event.get("eventType") == "translationTimedOut" and
                             event.get("operationID") == operation)), None)
        if deadline and not terminal:
            missing_terminal.extend([started_line, deadline[0]])
            start_generation = int(started.get("sessionGeneration", 0) or 0)
            end_generation = int(deadline[1].get("sessionGeneration", 0) or 0)
            if start_generation and end_generation > start_generation + 1:
                generation_jump.extend([started_line, deadline[0]])

    findings["APPLE-008"] = result(
        "FAIL" if queued_never_started else "PASS",
        "operation queued 后在 deadline/rebuild 前从未 started。" if queued_never_started
        else "未发现 queued-but-never-started operation。", queued_never_started
    )
    findings["APPLE-009"] = result(
        "FAIL" if missing_terminal else "PASS",
        "translationStarted 后 deadline/rebuild，但缺少 operationTerminal。"
        if missing_terminal else "所有 started deadline 路径都有 terminal。",
        missing_terminal
    )
    findings["APPLE-010"] = result(
        "WARNING" if generation_jump else "PASS",
        "单次 terminal/rebuild 出现超过设计值的 generation 跳跃。"
        if generation_jump else "未发现异常 generation 跳跃。", generation_jump
    )

    open_states = relevant(events, "openResourcePersistentState")
    free_states = [(line, event) for line, event in open_states
                   if "freedict" in str(event.get("resourceID", "")).lower()]
    free001 = [line for line, event in free_states
               if event.get("enabled") is True and event.get("publicationPresent") is False]
    findings["FREE-001"] = result(
        "FAIL" if free001 else ("PASS" if free_states else "WARNING"),
        "FreeDict enabled 但 publication 缺失。" if free001
        else ("FreeDict 未出现 enabled+missing publication。" if free_states
              else "本次证据没有 FreeDict persistent-state 事件。"), free001
    )
    free002 = [line for line, event in free_states
               if event.get("receiptPresent") is True and
               event.get("descriptorBuilt") is False and
               (event.get("enabled") is True or
                event.get("queryServiceRegistered") is True or
                str(event.get("statusPresented", "")) in {
                    "可用", "已安装", "Available", "Installed"
                })]
    findings["FREE-002"] = result(
        "FAIL" if free002 else ("PASS" if free_states else "WARNING"),
        "FreeDict 对外宣称可用，但 descriptor/publication identity 缺失。" if free002
        else ("缺失 publication 的 FreeDict 已安全 disabled/reinstall，不构成可用性冲突。" if free_states
              else "没有 FreeDict 证据。"), free002
    )
    free003 = [line for line, event in free_states
               if event.get("publicationPresent") is True and
               event.get("publicationIdentityValid") is False]
    findings["FREE-003"] = result(
        "FAIL" if free003 else ("PASS" if free_states else "WARNING"),
        "FreeDict SQLite 存在但 publication identity 无效。" if free003
        else ("未发现 SQLite/descriptor identity 不一致。" if free_states
              else "没有 FreeDict 证据。"), free003
    )
    free004 = [line for line, event in free_states
               if event.get("catalogState") == "ready" and
               "不可用" in str(event.get("statusPresented", ""))]
    findings["FREE-004"] = result(
        "FAIL" if free004 else ("PASS" if free_states else "WARNING"),
        "Resource/Catalog ready 但管理器显示 file unavailable。" if free004
        else ("未发现 Resource Center/Manager 状态冲突。" if free_states
              else "没有 FreeDict 证据。"), free004
    )
    free005 = [line for line, event in events
               if event.get("sourceOwnership") == "appManagedOpenResource" and
               (event.get("lifecycle") == "imported" or
                "用户原始导入" in str(event.get("statusPresented", "")))]
    findings["FREE-005"] = result(
        "FAIL" if free005 else "PASS",
        "managedOpenResource 错误进入 imported lifecycle。" if free005
        else "未发现 open resource 使用 imported lifecycle 语义。", free005
    )

    identities = defaultdict(set)
    identity_lines = defaultdict(list)
    for line, event in relevant(events, "aiStudyTextResolved"):
        key = (event.get("processSessionID"), event.get("queryGeneration"),
               event.get("provider"), event.get("model"))
        identity = event.get("aiStudyTextIdentityHash")
        if identity:
            identities[key].add(identity)
            identity_lines[key].append(line)
    ai001 = [line for key, values in identities.items() if len(values) > 1
             for line in identity_lines[key]]
    findings["AI-001"] = result(
        "FAIL" if ai001 else ("PASS" if identities else "WARNING"),
        "同 query/provider/model 出现不同 AIStudyText identity。" if ai001
        else ("AIStudyText identity 保持一致。" if identities
              else "未观察到 AIStudyText identity。"), ai001
    )

    clear_clicked = relevant(events, "aiCacheClearClicked")
    clear_completed = {(event.get("processSessionID"), event.get("queryGeneration"))
                       for _, event in relevant(events, "aiCacheCleared")}
    ai002 = [line for line, event in clear_clicked
             if (event.get("processSessionID"), event.get("queryGeneration"))
             not in clear_completed]
    findings["AI-002"] = result(
        "FAIL" if ai002 else ("PASS" if clear_clicked else "WARNING"),
        "点击清除此条 AI 缓存后未观察到完成事件。" if ai002
        else ("AI 缓存清理动作已完成。" if clear_clicked else "未执行 AI 缓存清理。"), ai002
    )

    ai003 = [line for line, event in relevant(events, "aiResultPresented")
             if event.get("safeVisibleContent") is True and
             (event.get("resultKind") in {"error", "failure", "incompatible"} or
              str(event.get("responseKind", "")).endswith("Failure"))]
    findings["AI-003"] = result(
        "FAIL" if ai003 else "PASS",
        "存在安全可见内容却进入 incompatible/error。" if ai003
        else "未发现可见 AI 内容被误判为 incompatible/error。", ai003
    )

    # A direction-sensitive cache hit is trustworthy only when the observable lookup carries
    # the complete routing identity. Legacy cache-hit presentations without that lookup are a
    # failure, because they are exactly how a Chinese result was reused for target=en.
    cache_lookups = relevant(events, "aiCacheLookup")
    ai004 = []
    required_cache_fields = {
        "aiCacheIdentityHash", "aiTranslationTargetLanguage",
        "promptVersion", "cacheSchemaVersion",
    }
    for line, event in cache_lookups:
        if event.get("aiCacheHit") is True and any(not event.get(key) for key in required_cache_fields):
            ai004.append(line)
    for line, event in relevant(events, "aiResultPresented"):
        if event.get("aiAction") != "deepTranslation" or event.get("cacheHit") is not True:
            continue
        matching = [(lookup_line, lookup) for lookup_line, lookup in cache_lookups
                    if lookup.get("processSessionID") == event.get("processSessionID") and
                    lookup.get("aiCacheHit") is True and
                    (lookup.get("queryHash") == event.get("queryHash") or
                     (lookup.get("aiCacheIdentityHash") and
                      lookup.get("aiCacheIdentityHash") == event.get("aiCacheIdentityHash")))]
        if not matching:
            ai004.append(line)
            continue
        lookup_line, lookup = matching[-1]
        for field in ("aiCacheIdentityHash", "aiTranslationTargetLanguage",
                      "promptVersion", "cacheSchemaVersion"):
            if event.get(field) != lookup.get(field):
                ai004.extend([lookup_line, line])
                break
        if lookup.get("queryRelation") and event.get("queryRelation") and \
                lookup.get("queryRelation") != event.get("queryRelation"):
            ai004.extend([lookup_line, line])
    findings["AI-004"] = result(
        "FAIL" if ai004 else ("PASS" if cache_lookups else "WARNING"),
        "AI 翻译缓存命中缺少完整方向 identity，或展示结果与 lookup identity 不一致。"
        if ai004 else ("AI 缓存命中与完整语言/目标 identity 一致。" if cache_lookups
                       else "未观察到 AI translation cache lookup。"), ai004
    )

    ai005 = [line for line, event in relevant(events, "aiResultValidated")
             if (event.get("aiResultValidation") != "accepted" or
                 event.get("aiWrongTargetRejected") is True) and
             event.get("resultKind") == "success"]
    findings["AI-005"] = result(
        "FAIL" if ai005 else "PASS",
        "错误目标语言的 AI 译文仍进入 success。" if ai005
        else "未发现错误目标语言 AI 译文被接受。", ai005
    )

    ai006 = [line for line, event in relevant(events, "aiSentenceRequestBuilt")
             if event.get("structuredOutputRequested") is True or
              (event.get("providerCapabilityMode") == "plainTextOnly" and
              (event.get("temperatureRequested") is True or
               (event.get("thinkingParameterRequested") is True and
                event.get("thinkingDisabledRequested") is False)))]
    ai006.extend(line for line, event in relevant(events, "providerRequestRejected")
                 if event.get("aiAction") == "sentenceAnalysis")
    findings["AI-006"] = result(
        "FAIL" if ai006 else ("PASS" if relevant(events, "aiSentenceRequestBuilt") else "WARNING"),
        "Sentence Analysis 请求了 provider 不支持的参数，或 production request 被拒绝。"
        if ai006 else ("Sentence Analysis 使用普通文本能力且未观察到参数拒绝。"
                       if relevant(events, "aiSentenceRequestBuilt")
                       else "未观察到 Sentence Analysis production request builder。"), ai006
    )

    presented_controls = relevant(events, "aiCacheClearPresented")
    ai007 = [line for line, event in presented_controls
             if event.get("controlType") != "NSButton" or
             event.get("controlEnabled") is not True]
    artifact_types = {
        "aiStudyTextResolved", "aiResultPresented", "aiWrongTargetRejected",
        "providerRequestRejected",
    }
    artifact_keys = {(event.get("processSessionID"), event.get("queryGeneration"))
                     for _, event in events if event.get("eventType") in artifact_types}
    presented_keys = {(event.get("processSessionID"), event.get("queryGeneration"))
                      for _, event in presented_controls
                      if event.get("controlType") == "NSButton" and
                      event.get("controlEnabled") is True}
    for key in artifact_keys - presented_keys:
        ai007.extend(line for line, event in events
                     if (event.get("processSessionID"), event.get("queryGeneration")) == key and
                     event.get("eventType") in artifact_types)
    findings["AI-007"] = result(
        "FAIL" if ai007 else ("PASS" if presented_controls else "WARNING"),
        "当前 query 存在 AI artifact，但没有可操作的 NSButton 缓存清理控件。"
        if ai007 else ("AI artifact 对应的统一缓存清理 NSButton 已显示。"
                       if presented_controls else "未观察到 AI cache-clear 控件。"), ai007
    )

    sentence_normalized = relevant(events, "aiSentenceResponseNormalized")
    ai008 = [line for line, event in sentence_normalized
             if event.get("normalizerDropReason") ==
             "normalizationDroppedVisibleContent"]
    findings["AI-008"] = result(
        "FAIL" if ai008 else ("PASS" if sentence_normalized else "WARNING"),
        "Sentence response 含潜在可见内容但被 normalizer 丢弃。" if ai008
        else ("Sentence response 未发生 visible-content drop。" if sentence_normalized
              else "未观察到新 schema 的 Sentence normalization 事件。"), ai008
    )

    sentence_starts = relevant(events, "aiSentenceRequestStarted")
    sentence_terminals = relevant(events, "aiSentenceOperationTerminal")
    sentence_retries = relevant(events, "aiSentenceRetryScheduled")
    ai009 = []
    for line, event in sentence_starts:
        request_id = event.get("requestID")
        session = event.get("processSessionID")
        completed = any(
            later_line > line and later.get("processSessionID") == session and
            later.get("requestID") == request_id
            for later_line, later in sentence_terminals + sentence_retries
        )
        if not completed:
            ai009.append(line)
    findings["AI-009"] = result(
        "FAIL" if ai009 else ("PASS" if sentence_starts else "WARNING"),
        "Sentence provider request 缺少 terminal/retry 事件。" if ai009
        else ("每个 Sentence provider request 都有 terminal 或有界 retry。"
              if sentence_starts else "未观察到 Sentence provider request。"), ai009
    )

    allowed_cancellation_reasons = {
        "userQueryChanged", "userRetry", "userCacheClear", "appQuit",
        "providerAbort", "studyTextSuperseded", "providerOrModelChanged",
        "generationMismatch", "internalReplacement",
    }
    cancellation_events = relevant(events, "aiSentenceCancellationRequested")
    orchestration_terminals = relevant(events, "aiSentenceOrchestrationTerminal")
    ai010 = [line for line, event in cancellation_events
             if event.get("typedReason") not in allowed_cancellation_reasons]
    ai010.extend(
        line for line, event in orchestration_terminals
        if event.get("resultKind") == "cancelled" and
        event.get("terminalReason") not in allowed_cancellation_reasons
    )
    findings["AI-010"] = result(
        "FAIL" if ai010 else ("PASS" if orchestration_terminals else "WARNING"),
        "Sentence cancellation 未记录允许的 typed reason。" if ai010
        else ("Sentence orchestration terminal 使用 typed reason。"
              if orchestration_terminals else "未观察到 Sentence orchestration terminal。"), ai010
    )

    inline_starts = relevant(events, "inlineAIRequestStarted")
    inline_clicks = relevant(events, "inlineAIActionClicked")
    inline001 = []
    for line, event in inline_starts:
        selection = event.get("selectionID")
        generation = event.get("selectionGeneration")
        clicked = any(
            click_line < line and click.get("processSessionID") ==
            event.get("processSessionID") and click.get("selectionID") == selection and
            (generation is None or click.get("selectionGeneration") == generation)
            for click_line, click in inline_clicks
        )
        if not clicked:
            inline001.append(line)
    findings["INLINE-001"] = result(
        "FAIL" if inline001 else ("PASS" if inline_starts else "WARNING"),
        "未点击 AI action 就启动了 Inline Provider request。" if inline001
        else ("Inline AI request 均由用户显式点击触发。" if inline_starts
              else "未观察到 Inline AI request。"), inline001
    )

    inline_normalized = relevant(events, "inlineAIResponseNormalized")
    inline002 = [line for line, event in inline_normalized
                 if event.get("normalizerDropReason") ==
                 "normalizationDroppedVisibleContent"]
    findings["INLINE-002"] = result(
        "FAIL" if inline002 else ("PASS" if inline_normalized else "WARNING"),
        "Inline response 含潜在可见内容但被 normalizer 丢弃。" if inline002
        else ("Inline response 未发生 visible-content drop。" if inline_normalized
              else "未观察到 Inline normalization 事件。"), inline002
    )

    inline003 = []
    removed_at = {}
    for line, event in events:
        selection = event.get("selectionID")
        if not selection:
            continue
        key = (event.get("processSessionID"), selection)
        if event.get("eventType") == "inlineCardRemoved":
            removed_at[key] = line
        elif event.get("eventType") in {"inlineCardReused", "inlineAISuccess",
                                        "inlineAIFailure"} and key in removed_at:
            inline003.extend([removed_at[key], line])
    findings["INLINE-003"] = result(
        "FAIL" if inline003 else "PASS",
        "旧 selection callback 在 card removed 后仍更新 UI。" if inline003
        else "未发现 stale selection callback 更新已移除卡片。", inline003
    )

    inline004 = []
    active_cards = set()
    card_events = [item for item in events if item[1].get("eventType") in {
        "inlineCardPresented", "inlineCardRemoved"
    }]
    for line, event in card_events:
        key = (event.get("processSessionID"), event.get("selectionID"))
        if event.get("eventType") == "inlineCardPresented":
            if key in active_cards:
                inline004.append(line)
            active_cards.add(key)
        else:
            active_cards.discard(key)
    findings["INLINE-004"] = result(
        "FAIL" if inline004 else ("PASS" if card_events else "WARNING"),
        "同一 selection 同时出现多个 Inline card。" if inline004
        else ("每个 selection 最多一个 Inline card。" if card_events
              else "未观察到 Inline card lifecycle。"), inline004
    )

    inline005 = []
    failures = relevant(events, "inlineAIFailure")
    removals = relevant(events, "inlineCardRemoved")
    for line, event in failures:
        session = event.get("processSessionID")
        selection = event.get("selectionID")
        boundary = next((later_line for later_line, later in events
                         if later_line > line and
                         later.get("processSessionID") == session and
                         (later.get("eventType") == "querySubmitted" or
                          (later.get("eventType") == "inlineSelectionCreated" and
                           later.get("selectionID") != selection))), None)
        if boundary is None:
            continue
        next_selection = next((later_line for later_line, later in events
                               if later_line > boundary and
                               later.get("processSessionID") == session and
                               later.get("eventType") == "inlineSelectionCreated"), 10**12)
        removed = any(line < removed_line < next_selection and
                      removal.get("processSessionID") == session and
                      removal.get("selectionID") == selection
                      for removed_line, removal in removals)
        if not removed:
            inline005.extend([line, boundary])
    findings["INLINE-005"] = result(
        "FAIL" if inline005 else "PASS",
        "切换 query/selection 后失败卡仍残留。" if inline005
        else "未发现失败卡跨 query/selection 残留。", inline005
    )

    inline006 = []
    for hit_line, hit in relevant(events, "localInlineLookupHit"):
        session = hit.get("processSessionID")
        selection = hit.get("selectionID")
        starts = [(line, event) for line, event in inline_starts
                  if line > hit_line and event.get("processSessionID") == session and
                  event.get("selectionID") == selection]
        for start_line, start in starts:
            clicked = any(hit_line < click_line < start_line and
                          click.get("processSessionID") == session and
                          click.get("selectionID") == selection
                          for click_line, click in inline_clicks)
            if not clicked:
                inline006.extend([hit_line, start_line])
    findings["INLINE-006"] = result(
        "FAIL" if inline006 else "PASS",
        "本地单词命中后未经点击仍触发了 AI。" if inline006
        else "本地单词命中未自动触发 AI。", inline006
    )

    lang001 = [line for line, event in events
               if event.get("queryRelation") == "mixedNativeDominant" and
               (event.get("translationTargetLanguage") is not None or
                event.get("targetLanguage") is not None) and
               event.get("translationTargetLanguage", event.get("targetLanguage")) !=
               event.get("learningLanguage")]
    lang002 = [line for line, event in events
               if event.get("queryRelation") == "mixedLearningDominant" and
               (event.get("translationTargetLanguage") is not None or
                event.get("targetLanguage") is not None) and
               event.get("translationTargetLanguage", event.get("targetLanguage")) !=
               event.get("nativeLanguage")]
    lang003 = [line for line, event in events if event.get("noOpTranslation") is True]
    lang004 = [line for line, event in relevant(events, "offlineStudyTextCreated")
               if event.get("studyTextOrigin") == "appleTranslation" and
               event.get("studyTextDeclaredLanguage") == "en" and
               event.get("resultLanguage") in {"zh-Hans", "mixedNativeDominant"}]
    lang005 = [line for line, event in events
               if event.get("queryRelation") == "mixedLearningDominant" and
               int(event.get("hanCharacterCount", 0) or 0) >= 12 and
               event.get("nativeCoverageBucket") == "high"]
    findings["LANG-001"] = result(
        "FAIL" if lang001 else "PASS",
        "中文主体 mixed query 未指向 learning language。" if lang001
        else "mixedNativeDominant 方向正确。", lang001
    )
    findings["LANG-002"] = result(
        "FAIL" if lang002 else "PASS",
        "学习语言主体 mixed query 未指向 native language。" if lang002
        else "mixedLearningDominant 方向正确。", lang002
    )
    findings["LANG-003"] = result(
        "FAIL" if lang003 else "PASS",
        "检测到与 source 高度一致的 no-op 翻译。" if lang003
        else "未发现 no-op translation 被当作成功。", lang003
    )
    findings["LANG-004"] = result(
        "FAIL" if lang004 else "PASS",
        "OfflineStudyText 声明学习语言但实际仍为母语。" if lang004
        else "OfflineStudyText 语言声明与结果一致。", lang004
    )
    findings["LANG-005"] = result(
        "FAIL" if lang005 else "PASS",
        "少量英文技术名词压过大量中文主体。" if lang005
        else "未发现 embedded term 主导 mixed 分类。", lang005
    )

    planned_operations = relevant(events, "offlineTranslationOperationPlanned")
    planned_targets = defaultdict(dict)
    planned_lines = defaultdict(list)
    for line, event in planned_operations:
        key = (event.get("processSessionID"), event.get("queryGeneration"),
               event.get("queryHash"))
        role = event.get("offlineOutputRole")
        if role:
            planned_targets[key][role] = event.get("offlineTargetLanguage") or \
                event.get("translationTargetLanguage")
            planned_lines[key].append(line)

    lang006 = []
    for key, roles in planned_targets.items():
        expected_role_target = {"learningVersion": "en", "nativeVersion": "zh-Hans"}
        plan_event = next((event for _, event in relevant(events, "offlineTranslationPlanCreated")
                           if (event.get("processSessionID"), event.get("queryGeneration"),
                               event.get("queryHash")) == key), None)
        if plan_event:
            expected_role_target = {
                "learningVersion": plan_event.get("offlineTranslationPairLearning"),
                "nativeVersion": plan_event.get("offlineTranslationPairNative"),
            }
        for role, target in roles.items():
            if role in expected_role_target and target != expected_role_target[role]:
                lang006.extend(planned_lines[key])
    for line, event in events:
        if event.get("eventType") not in {"appleTranslationRequested", "configurationCreated"}:
            continue
        role = event.get("offlineOutputRole")
        if role not in {"learningVersion", "nativeVersion"}:
            continue
        prior = [(planned_line, planned) for planned_line, planned in planned_operations
                 if planned_line < line and planned.get("processSessionID") ==
                 event.get("processSessionID") and planned.get("offlineOutputRole") == role]
        if not prior:
            continue
        planned_line, planned = prior[-1]
        actual = event.get("translationTargetLanguage") or event.get("targetLanguage")
        expected = planned.get("offlineTargetLanguage") or \
            planned.get("translationTargetLanguage")
        if actual != expected:
            lang006.extend([planned_line, line])
    findings["LANG-006"] = result(
        "FAIL" if lang006 else ("PASS" if planned_operations else "WARNING"),
        "Offline TranslationPlan 与 production target 不一致。" if lang006
        else ("Offline plan/output role 与 production target 一致。" if planned_operations
              else "旧证据未记录 production TranslationPlan，无法直接比对。"), lang006
    )

    lang007 = [line for line, event in relevant(events, "translationResultValidated")
               if event.get("resultKind") == "success" and
               (event.get("wrongTargetLanguage") is True or
                event.get("noOpTranslation") is True)]
    findings["LANG-007"] = result(
        "FAIL" if lang007 else "PASS",
        "Apple 结果目标语言不匹配却进入 success。" if lang007
        else "Apple wrong-target/no-op 结果未被当作成功。", lang007
    )

    lang008 = []
    for line, event in relevant(events, "offlineTranslationPlanCreated"):
        relation = event.get("queryRelation")
        explanation = event.get("explanationLanguage")
        native = event.get("offlineTranslationPairNative") or event.get("nativeLanguage")
        learning = event.get("offlineTranslationPairLearning") or event.get("learningLanguage")
        roles = planned_targets.get((event.get("processSessionID"),
                                     event.get("queryGeneration"), event.get("queryHash")), {})
        if relation == "native" and roles.get("learningVersion") != learning:
            lang008.append(line)
        if relation == "learning" and roles.get("nativeVersion") != native:
            lang008.append(line)
        if relation == "native" and explanation != learning and \
                roles.get("learningVersion") == explanation:
            lang008.append(line)
        if relation == "learning" and explanation != native and \
                roles.get("nativeVersion") == explanation:
            lang008.append(line)
    findings["LANG-008"] = result(
        "FAIL" if lang008 else ("PASS" if relevant(events, "offlineTranslationPlanCreated")
                                 else "WARNING"),
        "Explanation Language 泄漏到 Offline Translation target。" if lang008
        else ("Offline target 仅由 Native↔Learning pair 决定。"
              if relevant(events, "offlineTranslationPlanCreated")
              else "旧证据缺少 Explanation/Offline pair 字段，无法直接判断。"), lang008
    )

    lang009 = []
    mixed_plans = [(line, event) for line, event in relevant(events, "offlineTranslationPlanCreated")
                   if event.get("offlineTranslationPlan") in {
                       "mixedBidirectional", "unknownBidirectional"
                   }]
    for line, event in mixed_plans:
        key = (event.get("processSessionID"), event.get("queryGeneration"), event.get("queryHash"))
        roles = planned_targets.get(key, {})
        if set(roles) != {"learningVersion", "nativeVersion"} or \
                int(event.get("plannedOperationCount", 0) or 0) != 2:
            lang009.extend([line] + planned_lines.get(key, []))
    # Legacy schema fallback: a mixed GUI query followed by only one Apple target is already
    # conclusive user evidence, even if the older candidate did not emit plan events.
    for query_line, query in relevant(events, "querySubmitted"):
        if query.get("queryLanguage") != "mixed" or query.get("queryRelation"):
            continue
        session = query.get("processSessionID")
        next_query_line = next((line for line, event in events
                               if line > query_line and event.get("processSessionID") == session and
                               event.get("eventType") == "querySubmitted"), 10**12)
        requests = [(line, event) for line, event in relevant(events, "appleTranslationRequested")
                    if query_line < line < next_query_line and
                    event.get("processSessionID") == session]
        targets = {event.get("translationTargetLanguage") or event.get("targetLanguage")
                   for _, event in requests}
        if requests and targets != {query.get("nativeLanguage"), query.get("learningLanguage")}:
            lang009.extend([query_line] + [line for line, _ in requests])
    findings["LANG-009"] = result(
        "FAIL" if lang009 else ("PASS" if mixed_plans else "WARNING"),
        "mixed/unknown query 只创建了单方向 Offline operation。" if lang009
        else ("mixed/unknown query 已创建 Native 与 Learning 两个 operation。"
              if mixed_plans else "未观察到 mixed/unknown query。"), lang009
    )

    lang010 = [line for line, event in relevant(events, "translationResultValidated")
               if event.get("offlineOutputRole") in {"learningVersion", "nativeVersion"} and
               event.get("wrongTargetLanguage") is True]
    findings["LANG-010"] = result(
        "FAIL" if lang010 else "PASS",
        "mixed output role 的结果语言不符合目标语言。" if lang010
        else "未发现 mixed output language invalid。", lang010
    )

    lang011 = []
    terminals = relevant(events, "operationTerminal")
    starts = relevant(events, "nextOperationStarted")
    for line, terminal in terminals:
        role = terminal.get("offlineOutputRole")
        if role not in {"learningVersion", "nativeVersion"} or \
                terminal.get("resultKind") in {"success", "partialSuccess"}:
            continue
        other = "nativeVersion" if role == "learningVersion" else "learningVersion"
        session = terminal.get("processSessionID")
        other_starts = [(start_line, start) for start_line, start in starts
                        if start.get("processSessionID") == session and
                        start.get("offlineOutputRole") == other]
        if role == "learningVersion":
            recovered = any(start_line > line for start_line, _ in other_starts)
        else:
            recovered = bool(other_starts)
        if not recovered:
            lang011.append(line)
    findings["LANG-011"] = result(
        "FAIL" if lang011 else "PASS",
        "mixed 一侧失败阻止了另一侧 operation 启动。" if lang011
        else "未发现 mixed side failure 污染另一侧。", lang011
    )
    return findings


def render(path, events, findings):
    statuses = [value[0] for value in findings.values()]
    overall = "FAIL" if "FAIL" in statuses else ("WARNING" if "WARNING" in statuses else "PASS")
    session_ids = sorted({str(event.get("processSessionID")) for _, event in events
                          if event.get("processSessionID")})
    output = [
        "# LocalDictionary Evidence Summary", "",
        f"- Overall: **{overall}**",
        f"- Evidence file: `{path.name}`",
        f"- Parsed events: {len(events)}",
        f"- Process sessions: {len(session_ids)}", "",
        "说明：此报告只引用事件行号、状态和匿名 identity，不复述查询或 AI 正文。", "",
        "## Rules", "",
    ]
    for rule in ["EVIDENCE-SAFETY"] + RULES:
        status, message, evidence = findings[rule]
        output.extend([
            f"### {rule} — {status}", "",
            message,
            f"相关 JSONL 行：{lines(evidence)}" if evidence else "相关 JSONL 行：—",
            "",
        ])
    return "\n".join(output)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("evidence", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if not args.evidence.is_absolute() or not args.evidence.is_file():
        print("Evidence path must be an existing absolute JSONL file.", file=sys.stderr)
        return 2
    events, errors = load_events(args.evidence)
    findings = analyze(events, errors)
    report = render(args.evidence, events, findings)
    output = args.output or args.evidence.with_name("EVIDENCE-SUMMARY.md")
    output.write_text(report, encoding="utf-8")
    print(output)
    return 1 if any(value[0] == "FAIL" for value in findings.values()) else 0


if __name__ == "__main__":
    raise SystemExit(main())
