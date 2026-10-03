# Research Case 与阅读证据升级 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在现有 research-workbench 中修复结果包重复导入，增加可追溯的科研关系/演进/执行记录和可定位、可搜索的阅读证据，保留离线交换。

**Architecture:** 保持当前 Flutter + Dart + SQLite 应用及现有 `research-package-v1`/task/result v1 兼容。新增小型领域对象、追加迁移、派生阅读索引与窄端口；界面只消费领域读模型。研究质量以来源明确的提示记录，实际执行授权、外传确认和交换文件校验另行强制。

**Tech Stack:** Flutter/Dart SDK `>=3.10.0 <4.0.0`，`sqlite3 3.6.0`，`pdfrx 2.6.5`，`flutter_markdown_plus`，现有 `archive`/`crypto`；Android、macOS、Windows 原生工程。PaddleOCR 是待逐端核准并验收的候选适配器，尚非已集成依赖。

**Spec:** [融合案例规格](../specs/2026-10-03-integrated-research-case-design.md)；[阅读升级规格](../specs/2026-10-03-research-reading-upgrade-design.md)。两份规格已存在且获准进入计划阶段；其“待审阅”旧标题与此前的流程门槛措辞以 2026-10-03 用户决策补充为准。

## Global Constraints

- 本轮只写/审阅计划，不修改产品代码、独立 research-skill、模型或平台工程，不安装、不推送。执行任务须待用户选定方式后开始。
- **不新建科研 APP，不迁移生产技术栈。** Flutter/Tauri 探针仅供将来外壳判断；本计划在现有工作台实施。若用户以后批准迁移，重新审定界面与原生 OCR 任务。
- 科研探索没有强制阶段顺序、候选数量、证据齐备或通用审批门槛。可选 `WorkflowDefinition` 只给路径提示；关系地图、演进时间线、任务执行记录是三个视图。AI 分析是带来源、可修改的建议。
- 原 skill 保持独立；V6.6 `b09f09499dd2ac64317dd1291532e5aac562fae8` 为新案例默认方法来源，V6.4 历史提交 `03f768c8526fb9d9c1d31ae808b36c5e17e77c25` 保真导入。两者 JSONL `schema_version:2` 不等于应用包版本。skill 原校验结论忠实显示，APP 不改判、不自动写回源日志。
- 命令与代码在包内是数据；导入、阅读、手机批准记录都不会运行它们。真实执行与数据外传须分别明确授权；断联执行状态为 `unknown`，不得自动重派。
- 原始 Markdown/PDF/JSONL 快照不可变。派生文本、OCR、图像、译文和 AI 建议保留输入哈希、来源、版本、人工状态。旧笔记/任务/运行和 v1 包必须继续可读。
- 每项迁移追加到当前 `WorkbenchStore._migrations` 尾部，执行前按实际分支版本重核，先备份用户库并保留回退副本；不要修改已有迁移或覆盖 dirty 文件。未来提交只暂存该任务列出的路径。

## Review Focus

以下五类高风险输入必须分别被对应任务的测试覆盖：

1. 同 run ID 的本机公开字段相同、键顺序不同、带内部字段：任务 1 验证幂等且保持 `accepted`；公开字段变化仍拒绝。
2. 历史 V6.4 行缺 `decisive_neighbors`、V6.6 可选 `subq/intent`：任务 3 验证保真及“待复核”提示，不改原判决。
3. 旧库与文档换版：任务 2、6、8 验证迁移保留旧记录，哈希变化使位置/卡片待复核。
4. 包内未列文件、坏哈希、同 attempt 不同执行者或断联：任务 5 验证拒收/冲突/`unknown`，不自动运行或重派。
5. 无索引/无 OCR 模型及扫描低置信页：任务 7、9 验证原文仍可读，搜索状态可辨，摘录不伪造精确引用。

---

## 文件责任与依赖

| 文件 | 责任 |
| --- | --- |
| `lib/core/result_payload.dart`（新） | 公开结果字段的递归规范比较；本地内部字段不参与，但未知公开字段参与 |
| `lib/core/case_models.dart`（新）、`lib/core/case_store.dart`（新） | MethodSpec、可选模板、ResearchCase、PlanVersion、ExecutionAttempt、来源引用与追加事件；不含 UI |
| `lib/core/store.dart`（改） | 仅追加迁移及既有库入口；案例/阅读表由独立 repository 操作 |
| `lib/core/research_skill.dart`（改） | V6.6 与 V6.4 只读投影、原始行保真、提示来源；草稿仍待审 |
| `lib/core/exchange.dart`（改）、`lib/core/case_exchange.dart`（新） | 修复 v1 重复导入；v2 可选案例/attempt 关联与完整 manifest，保留 v1 |
| `lib/app/case_views.dart`（新）、`lib/app/workbench_app.dart`（改） | 关系地图、演进时间线、执行记录与简洁进度入口；不重排全应用 |
| `lib/reader/reading_repository.dart`、`document_text.dart`、`reading_index.dart`、`evidence_repository.dart`、`ocr_port.dart`（新） | 阅读位置、文字层、项目索引、证据卡与区域、OCR 接口；原始文件只读 |
| `lib/reader/reader_page.dart`（改）、`lib/app/skill_panels.dart`（改） | 导航、搜索、选区、证据卡入口及方法提示 |
| `lib/app/case_comparison_page.dart`（新） | 同一案例/问题下的跨论文证据、任务、运行与科学判断比较 |

任务 1–3、5、6 中的数据契约与迁移不依赖 Flutter/Tauri 探针；任务 4、7–11 以**当前 Flutter 生产栈**实施，不因探针自动迁移。PaddleOCR 原生打包须单独通过三端许可/工具链/运行验收，模拟端口测试不算真实 OCR。

## 阶段 A：先修回导，再建立记录和交换

### Task 1: 结果包同 ID 语义幂等

**Files:** Create `lib/core/result_payload.dart`; modify `lib/core/exchange.dart:599-744`, `lib/core/store.dart:340-407`, `lib/app/workbench_app.dart:1190-1220`; test `test/core_test.dart`, `test/run_comparison_test.dart`.

**Interfaces:** Produce `Map<String, dynamic> publicResult(Map<String, dynamic> value)` and `bool samePublicResult(Map<String, dynamic> a, Map<String, dynamic> b)`. Only remove known local metadata `_localManual`/`_snapshotPath`/`_exportedDigest`; recursively sort map keys, retain list order and every other public field. ZIP artifact bytes participate through sorted manifest SHA-256 values. A local manual run records one immutable `_exportedDigest` receipt for its first export; exact repeat is idempotent, changed payload under the same run ID requires a new run/attempt.

- [ ] **Step 1: Write failing tests.** Add `localExportReimportIsIdempotent`: create manual run, export ZIP, import same ZIP; assert `expect(imported.id, original.id)`, `expect(store.runs(project.id), hasLength(1))` and previous `accepted` unchanged. Add `resultMapOrderDoesNotConflict`, `changedMetricSameIdConflicts`, `firstImportOnOtherStoreAndRepeat`, `manualArtifactExportReimportsExactZip`, `sameArtifactNameChangedBytesConflicts`, `reExportChangedRunRequiresNewRun`, `unknownTaskRevisionAndBadArtifactStillFail`. Widget test `completedManualRunCanBeAccepted` asserts the explicit “确认关联为证据” action appears on a finished local run and the accepted flag changes only after confirmation.
- [ ] **Step 2: Run tests to observe failure.** `flutter test test/core_test.dart --plain-name 'localExportReimportIsIdempotent'`; expected current `Run ID already exists with different contents`.
- [ ] **Step 3: Implement the two signatures in `result_payload.dart` and replace the JSON-string comparison in `importResult`.** Build exported JSON from public fields, preserving unknown public extensions, then set artifact descriptors. After package assembly, persist the first canonical public-payload-plus-artifact-hash receipt in local metadata without changing acceptance; a later different export of the same run ID fails explicitly. For imported duplicates compare both public fields and verified artifact hashes from stored/new snapshots. Keep existing task/manifest verification and accepted column; never delete or rewrite an existing run to satisfy comparison. In `workbench_app.dart`, offer explicit acceptance for finished local manual records as well as imported records; do not auto-accept on export or reimport.
- [ ] **Step 4: Run `flutter test test/core_test.dart` and `flutter test test/run_comparison_test.dart`; expected PASS**, including accepted after duplicate import.
- [ ] **Step 5: Commit only these paths** with `fix: make result reimport semantically idempotent`.

### Task 2: 案例契约与追加式 SQLite 存储

**Files:** Create `lib/core/case_models.dart`, `lib/core/case_store.dart`; modify `lib/core/store.dart:16-43`; test `test/case_store_test.dart`.

**Interfaces:** Produce `SourceRef(snapshotId,kind,sourceId,rev)`, `ResearchCase`, `PlanVersion`, `ExecutionAttempt`; `CaseStore.saveCase(ResearchCase)`, `appendPlan(PlanVersion)`, `appendEvent(caseId,type,sourceRefs,payload)`, `createAttempt(ExecutionAttempt)`, `caseTimeline(caseId)`. Store explicit method commit and optional workflow reference. Never infer skill rev from plan version or task revision.

- [ ] **Step 1: Write failing tests.** `caseCanHaveZeroCandidatesAndSkipStages`; `planChangeCreatesVersionWithReasonAndBranch`; `caseTimelineKeepsRejectedAndRestartedBranches`; `oldV5DatabaseUpgradesWithoutChangingExistingRows`; `attemptProcessStatusIsSeparateFromScientificJudgement`.
- [ ] **Step 2: Run `flutter test test/case_store_test.dart`; expected missing API or migration failure.**
- [ ] **Step 3: Append one v6 migration and implement the typed repository.** Tables: `research_cases`, `plan_versions`, `execution_attempts`, `case_events` with primary keys and project/case/plan references; store event payload and sourceRefs JSON, immutable old versions. Add pre-migration checked backup before changing an existing DB; a failed backup aborts migration. Use the actual current schema version again before editing.
- [ ] **Step 4: Run `flutter test test/case_store_test.dart test/core_test.dart`; expected PASS** and user_version 6 on the v5 fixture. A backup/reopen check must prove existing notes/tasks/runs remain byte-equivalent at the business fields.
- [ ] **Step 5: Commit listed paths** with `feat: record research cases and plan history`.

### Task 3: Skill 只读映射与质量提示

**Files:** Modify `lib/core/research_skill.dart`, `lib/app/skill_panels.dart`; test `test/research_skill_test.dart`, `test/skill_ui_test.dart`, `test/skill_fixture.dart`.

**Interfaces:** Produce `SkillReviewHint reviewHint(RevisionGroup group, String methodCommit)` and `List<SourceRef> decisiveNeighborRefs(ResearchEntry opportunity)`; consume Task 2 `SourceRef`. Hint fields include source method/version, severity, reason and `needsReview`, never mutate `ResearchEntry.data`.

- [ ] **Step 1: Write failing tests.** Synthetic V6.6 row preserves `searches.subq/intent`, shows discovery-yield as hint, links `decisive_neighbors:[{id,rev}]`; V6.4 actionable row without that field retains its original decision plus “按当前方法待复核”. Unknown fields survive import/export; no files in skill root are changed.
- [ ] **Step 2: Run `flutter test test/research_skill_test.dart test/skill_ui_test.dart`; expected new assertions FAIL.**
- [ ] **Step 3: Implement projection and badges only.** V6.6 method defaults to fixed commit; historical snapshot may keep V6.4. Do not run `check-research.py` from the app or loosen its existing validator; draft export stays `needs_review`.
- [ ] **Step 4: Run the same two test files; expected PASS.**
- [ ] **Step 5: Commit listed paths** with `feat: display versioned skill review hints`.

### Task 4: 三个研究记录视图

**Files:** Create `lib/app/case_views.dart`; modify `lib/app/workbench_app.dart`; test `test/case_views_test.dart`.

**Interfaces:** Consume `CaseStore.caseTimeline(caseId)` and Task 2 objects. Expose `CaseViews(store,caseId)` with relationship map, plan evolution timeline, execution ledger and a compact progress/next-action header. “Stage” is display state only.

- [ ] **Step 1: Write failing widget tests.** `zeroCandidatesAndMissingEvidenceDoNotDisableEditing`; `timelineShowsReasonForkRejectRestart`; `aiSuggestionShowsSourceAndCanBeEditedWithoutBecomingFact`; `attemptCompletedDoesNotShowScientificSuccess`.
- [ ] **Step 2: Run `flutter test test/case_views_test.dart`; expected FAIL.**
- [ ] **Step 3: Implement the three tabs/read models and wire from existing project page.** Use actual source refs for links; missing evidence shows a gap/next action, never a disabled research button. Source-free AI text remains an unconfirmed draft and cannot masquerade as evidence.
- [ ] **Step 4: Run `flutter test test/case_views_test.dart test/workbench_test.dart`; expected PASS at phone and desktop widget sizes.**
- [ ] **Step 5: Commit listed paths** with `feat: visualize research relationships and evolution`.

### Task 5: 封装离线任务/结果关联与执行边界

**Files:** Create `lib/core/case_exchange.dart`; modify `lib/core/exchange.dart`, `lib/core/case_store.dart`, `lib/app/workbench_app.dart`; test `test/case_exchange_test.dart`, `test/core_test.dart`, `test/case_views_test.dart`.

**Interfaces:** Produce `CaseExchange.exportAttempt(attemptId,destinationDirectory)` and `importAttemptResult(path)`; consume Task 2 `ExecutionAttempt`. New `research-task-v2`/`research-result-v2` add optional `caseRef/methodRef/planRef/attemptId/executorId/approvalRef/inputManifest`; v1 remains accepted as unlinked history.

- [ ] **Step 1: Write failing tests.** v1 packages still import; a v2 package lists every decision-relevant file in manifest and validates path/size/hash before storing; same ID/same payload is idempotent, same ID/different payload conflicts; an attempt has exactly one executor; import never starts a process; no approval means package is a draft, not executable; disconnect sets `unknown` without auto-resend.
- [ ] **Step 2: Run `flutter test test/case_exchange_test.dart`; expected FAIL.**
- [ ] **Step 3: Implement versioned codec and attempt receipt.** Explicitly record code commit, environment lock/hash, input data manifest/split/license, command/parameters, budget, output requirements and approval scope; selected bytes only, never scan or bundle credentials. Return manifests include actual versions, logs, raw result/artifact hashes and deviations. Wire explicit package export/import actions to the current UI; distinct run status, acceptance and scientific judgement remain distinct.
- [ ] **Step 4: Run `flutter test test/case_exchange_test.dart test/core_test.dart test/lan_transfer_test.dart`; expected PASS.**
- [ ] **Step 5: Commit listed paths** with `feat: bind offline packages to authorized attempts`.

## 阶段 B：阅读定位与证据

### Task 6: 阅读位置与大纲

**Files:** Create `lib/reader/reading_repository.dart`; modify `lib/core/store.dart`, `lib/reader/reader_page.dart`; test `test/reading_position_test.dart`.

**Interfaces:** Produce `ReadingRepository.savePosition(documentId,documentSha256,locator,scrollRatio,zoom)` and `positionFor(documentId,currentSha256)` returning `exact/stale/none`; `DocumentOutline` uses PDF physical page or Markdown heading, not printed page.

- [ ] **Step 1: Write failing tests.** Reopen restores same-hash PDF page/Markdown heading; changed hash returns stale and requires review; page jump and Markdown heading outline work; old notes survive migration; invalid page is rejected without losing position.
- [ ] **Step 2: Run `flutter test test/reading_position_test.dart`; expected FAIL.**
- [ ] **Step 3: Append v7 reading-position table and add small navigation controls to existing reader.** Keep page/heading, scroll ratio and zoom separate; never silently re-anchor a changed PDF.
- [ ] **Step 4: Run `flutter test test/reading_position_test.dart test/reader_evidence_test.dart`; expected PASS.**
- [ ] **Step 5: Commit listed paths** with `feat: restore versioned reading positions`.

### Task 7: 文本层与项目搜索

**Files:** Create `lib/reader/document_text.dart`, `lib/reader/reading_index.dart`; modify `lib/core/store.dart`, `lib/reader/reader_page.dart`, `lib/app/workbench_app.dart`; test `test/reading_search_test.dart`.

**Interfaces:** `DocumentTextPort.extract(document,page)` returns text spans/coordinates and source `pdf_text/markdown/ocr`; `ReadingIndex.indexDocument(document,layer)`, `search(projectId,query)`, `status(documentId)`. PDF adapter may call `PdfPage.loadText/loadStructuredText` only after verifying the locked pdfrx API against actual local package.

- [ ] **Step 1: Write failing tests.** Markdown headings/body and text PDF are searchable within one project; hit navigates to physical page or heading; another project's text cannot leak; no index or extraction failure returns `not_indexed/error`, not “zero matches”; changed document hash invalidates only its derived layer. Add Chinese phrase fixture for actual FTS behavior.
- [ ] **Step 2: Run `flutter test test/reading_search_test.dart`; expected FAIL.**
- [ ] **Step 3: Append v8 derived layer/index schema; implement bounded per-document extraction and FTS if present.** If SQLite build lacks required FTS/tokenization on a target, use an explicitly tested bounded fallback; do not silently claim complete Chinese full-text indexing.
- [ ] **Step 4: Run `flutter test test/reading_search_test.dart test/workbench_test.dart`; expected PASS; verify search status and no source mutation.**
- [ ] **Step 5: Commit listed paths** with `feat: search versioned document text`.

### Task 8: 可回跳的文字与图表证据卡

**Files:** Create `lib/reader/evidence_repository.dart`; modify `lib/core/store.dart`, `lib/reader/reader_page.dart`, `lib/core/exchange.dart`; test `test/evidence_card_test.dart`.

**Interfaces:** `EvidenceRepository.createTextCard(documentId,locator,quote,context,source)`, `createRegionCard(documentId,page,normalizedRect,imageBytes)`, `openLocator(cardId,currentDocumentSha256)` returning exact/stale; consume `SourceRef` and reading layer metadata. Original quote/region immutable; interpretation/review state separately editable.

- [ ] **Step 1: Write failing tests.** Card stores document SHA, paper ID/rev, PDF physical page or Markdown heading, normalized rect, quote/context, extraction method/confidence; click returns to source; changed hash or mismatch marks stale; old freeform note remains and converts only on explicit action; image hash changes only in derived storage, never source PDF.
- [ ] **Step 2: Run `flutter test test/evidence_card_test.dart`; expected FAIL.**
- [ ] **Step 3: Append v9 evidence-card/region tables and implement storage with private derived files.** Add bounded region size and safe path handling; link export report to cards without changing v1 report behavior for old notes.
- [ ] **Step 4: Run `flutter test test/evidence_card_test.dart test/reader_evidence_test.dart test/core_test.dart`; expected PASS.**
- [ ] **Step 5: Commit listed paths** with `feat: anchor immutable reading evidence`.

### Task 9: OCR 端口、模拟验收与缺模型降级

**Files:** Create `lib/reader/ocr_port.dart`; modify `lib/reader/document_text.dart`, `lib/reader/reader_page.dart`; test `test/ocr_port_test.dart`.

**Interfaces:** `OcrPort.recognize(pageImage,language)` returns text boxes, confidence, model ID/version; `OcrAvailability` reports available/unavailable reason. OCR layer feeds Task 7 search and Task 8 draft cards with `source=ocr`, never “verified”.

- [ ] **Step 1: Write failing tests with fake OCR.** Low-text scan routes only requested page/region to port; absent model leaves PDF/manual notes usable; low confidence, rotated/multicolumn and cancellation display recoverable status; OCR draft does not assert precise verified quote.
- [ ] **Step 2: Run `flutter test test/ocr_port_test.dart`; expected FAIL.**
- [ ] **Step 3: Implement port and fake-backed flow only.** No PaddleOCR package, model download, desktop Python bridge or “三端已支持” claim in this task.
- [ ] **Step 4: Run `flutter test test/ocr_port_test.dart test/reading_search_test.dart`; expected PASS; mark result as simulated adapter acceptance only.**
- [ ] **Step 5: Commit listed paths** with `feat: add optional offline OCR interface`.

### Task 10: PaddleOCR 真正的平台适配

**Files:** Create `lib/reader/ocr_native/paddle_ocr_adapter.dart`, `integration_test/ocr_native_test.dart`, `docs/ocr-native-acceptance.md`; conditionally modify `pubspec.yaml`, `android/app/src/main/kotlin/com/muyi/research_workbench/MainActivity.kt`, `macos/Runner/AppDelegate.swift`, `windows/runner/flutter_window.cpp`, `windows/runner/CMakeLists.txt` after the native runtime decision. If a different plugin entry point is required, revise this file list at the license/toolchain gate before coding.

**Interfaces:** Implement Task 9 `OcrPort` with bundled or explicit local model import. Record exact PaddleOCR/runtime/model/third-party licenses, target architectures, size, inference latency and offline behavior in `docs/ocr-native-acceptance.md`.

- [ ] **Step 1: Write integration fixture and acceptance assertions.** On each platform, a known scanned PDF page yields OCR text/boxes with correct page and model version, no network request; missing model degrades cleanly; source PDF hash unchanged.
- [ ] **Step 2: Check license, redistribution rights, native toolchain and model packaging per Android/macOS/Windows before adding a dependency.** If any target lacks lawful/supportable native runtime, record it as blocked and do not call Task 9's fake a production implementation.
- [ ] **Step 3: Implement one platform adapter at a time through Task 9 port; avoid runtime download and avoid using macOS Python as an Android/Windows claim.**
- [ ] **Step 4: On each available native target run `flutter test integration_test/ocr_native_test.dart -d <device-id>` and a release build/open test.** Record actual device/OS/model/license/latency in `docs/ocr-native-acceptance.md`; Windows remains explicitly **untested** until a Windows host performs this gate. Unit/widget tests cannot substitute for this step.
- [ ] **Step 5: Commit only verified platform paths and acceptance record** with `feat: integrate verified offline OCR adapters`. Unverified target stays disabled with a visible reason.

## 阶段 C：比较、报告与原生回路

### Task 11: 问题比较板与证据报告

**Files:** Create `lib/app/case_comparison_page.dart`; modify `lib/core/case_store.dart`, `lib/core/exchange.dart`, `lib/app/workbench_app.dart`; test `test/case_comparison_test.dart`.

**Interfaces:** `CaseStore.comparison(caseId,questionId)` returns evidence refs, paper revisions, plan/attempt/run IDs and separate scientific judgement; `ResearchExchange.exportReport` adds case evidence appendix while preserving old reports.

- [ ] **Step 1: Write failing tests.** Two papers under one question show supports/conflicts/unknown with source jump; report cites `kind/id@rev`, document hash and accepted run only; technical completed is not scientific support; negative/inconclusive/failed attempts and plan restart remain visible; no candidate is a valid case.
- [ ] **Step 2: Run `flutter test test/case_comparison_test.dart`; expected FAIL.**
- [ ] **Step 3: Implement read-only comparison projection and report appendix.** Reuse Task 8 cards and Task 2 case IDs; do not create a second candidate or evidence database. AI-generated prose, if shown, is editable advice with source and cannot change accepted judgement automatically.
- [ ] **Step 4: Run `flutter test test/case_comparison_test.dart test/core_test.dart test/run_comparison_test.dart`; expected PASS.**
- [ ] **Step 5: Commit listed paths** with `feat: compare source-linked case evidence`.

### Task 12: 设备与迁移验收记录

**Files:** Create `docs/research-case-reading-acceptance.md`, `integration_test/roundtrip_test.dart`; test existing `test/core_test.dart`, `test/reading_position_test.dart`, `test/case_exchange_test.dart`. There is currently no `integration_test/` directory; this task creates it.

**Interfaces:** Acceptance matrix records actual build/device, package hashes, source PDF hashes, old/new schema, task/run/attempt identities, export/import/acceptance/report outcomes. This task produces evidence, not new behavior.

- [ ] **Step 1: Prepare synthetic v5 DB, V6.4/V6.6 logs, text/scanned PDFs, task/result packages and a second clean install.** No real research data or command execution.
- [ ] **Step 2: Run `flutter analyze` and the task-specific test files, then `flutter test`; record actual pass/fail counts rather than assuming success.**
- [ ] **Step 3: On Android, macOS and Windows individually validate old DB migration, import/open/search/save/reopen/export through native file pickers.** Windows gate remains untested if no Windows environment is supplied; one Android phone cannot satisfy desktop acceptance.
- [ ] **Step 4: On two installed instances validate first result return, human acceptance and report; separately reimport identical package on origin and test true-content conflict.** Disconnect mid-attempt and verify `unknown` with no automatic retry; do not infer live cross-network execution from manual file transfer.
- [ ] **Step 5: Save the matrix and unresolved findings; commit only the acceptance document and any already reviewed harness change** with `docs: record native research workflow acceptance`.

## 后续独立计划与未决条件

阅读规格第三阶段的段落翻译、桌面可选 BabelDOC、联网/本地引用式 AI，以及未来统一平台任务/消息/对象/OCR/RAG 适配，不在本计划的首个可交付闭环内。启动它们前需单独审阅数据外传 UI、BabelDOC AGPL-3.0 与部署方式、模型及第三方许可和分发、平台对象所有权、Windows 工具链与真实性能。本计划不声称这些能力已测试或可上线。

## 自查与执行交接

- 规格覆盖：同 ID 冲突→1；方法/案例/历史→2–4；任务与安全交换→5；导航/检索/证据/OCR→6–10；跨论文/报告→11；旧库、双设备、三端→12。翻译、BabelDOC、AI、统一平台明确列为后续独立计划。
- 类型一致：`SourceRef` 仅由任务 2 定义；任务 3/8/11 消费。过程状态、科学判断、结果接纳分开。OCR fake 与真正原生适配分开。
- 尚未运行任何计划中的测试或原生验收；本文件是实施步骤，不是完成报告。
