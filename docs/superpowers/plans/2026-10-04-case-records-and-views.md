# 任务 2–4：案例存储、方法提示与三个记录视图

日期：2026-10-04。基线：`main` @ `28af290`（#15 已合入结果包语义幂等）。本文件取代 [2026-10-03 实施计划](2026-10-03-research-case-reading-implementation.md) 的任务 2、3、4。任务 1 已完成，不要重做。任务 5–12 仍以那份计划为准，且必须接在本文件的对象之后。

**Goal:** 在现有 Flutter 工作台里记下可追溯的研究案例、计划版本和执行尝试，按方法版本显示 skill 质量提示，并用三个视图阅读这些记录。

**Architecture:** 案例表由独立的 `CaseStore` 操作。`WorkbenchStore` 只在迁移列表末尾追加一步，并继续拥有数据库连接。界面只读这些对象和已经导入的 JSONL，不改 skill 源文件，不运行命令。

## 当前基线（实施前再核对一次）

- `lib/core/store.dart` 的 `_migrations` 有 6 步，`schemaVersion` 为 6。v5 是 research-skill 布局、文档哈希和论文绑定。v6 是笔记关联研究记录，以及提纲按标题分成 `sections`。**下一次迁移把 `user_version` 从 6 升到 7。** 禁止改已有迁移，禁止再把案例表写成 v6。
- `RevisionGroup.needsReview`（`lib/core/research_skill.dart`）只反映行内 `status` / `review_status == needs_review`。这不是方法版本提示，保留它。
- 底栏已经有 6 个分区。手机 `NavigationBar` 只放前 5 个（`workbench_app.dart` 约 427 行），「研究关系」是现有记录关系图。案例视图不要做成第 7 个分区，也不要替换这个关系图。
- `feat/research-case-reading` 工作区里未跟踪的 `test/case_store_test.dart` 不能编译，也只覆盖五则测试中的一则。不要提交它。按下面的测试名重写。
- 不把 `refactor/extract-pages` 当作前置。那条分支相对 `main` 有冲突，本计划只在 `overview()` 加一个入口。

## 全局约束

- 仍是当前 Flutter / Dart / SQLite 应用。不新建应用，不迁移技术栈，不接 OCR、翻译或统一平台。
- 科研过程不强制阶段顺序、候选数量或证据齐备。`processState`、`scientificJudgement`、运行 `status`、结果 `accepted` 分开存储和展示。
- 新案例默认方法提交是 V6.6 `b09f09499dd2ac64317dd1291532e5aac562fae8`。导入的历史案例可以保留 V6.4 `03f768c8526fb9d9c1d31ae808b36c5e17e77c25`。不得从计划版本或任务修订推断 skill 的 `rev`。
- 原始 JSONL 和快照不可变。应用不调用 `check-research.py`，不改 skill 根目录里的文件。claim 草稿仍是 `needs_review`。
- `SourceRef` 只在任务 2 定义。任务 3 和任务 4 消费它。
- 迁移只追加。对**已经存在**的库，在执行新迁移之前先做可打开的备份；备份失败就中止，不改原库。新建的空库不必留备份。
- 每个任务只暂存该任务列出的路径。

## 顺序

任务 3 和任务 4 都只依赖任务 2。任务 4 的界面留出提示位置；任务 3 未合入时该位置为空，测试不要求出现 discovery-yield 文案。二者可以并行，但不要在任务 2 的表落地之前写视图或提示。

---

### Task 2: 案例契约与追加式 SQLite 存储

**Files:** Create `lib/core/case_models.dart`, `lib/core/case_store.dart`; modify `lib/core/store.dart`（只追加迁移，并让 `CaseStore` 能使用现有 `db`）; test `test/case_store_test.dart`.

**Interfaces:**

- `SourceRef(snapshotId, kind, sourceId, rev)`。四个字段都显式保存。
- `ResearchCase`：`id`、`projectId`、`question`、`methodCommit`、可选 `workflowId`、`candidates`（`SourceRef` 列表，允许空）、`processState`、`scientificJudgement`。
- `PlanVersion`：`planId`、`version`、`caseId`、`parentVersion`、`reason`、`branch`。旧版本不覆盖。
- `ExecutionAttempt`：`attemptId`、`caseId`、`planId`、`planVersion`、可选 `taskId` 与 `taskRevision`、唯一 `executorId`、`processStatus`。过程状态不是科学判断。
- `CaseStore.saveCase`、`caseById`、`appendPlan`、`appendEvent(caseId, type, sourceRefs, payload)`、`createAttempt`、`caseTimeline(caseId)`。
- 事件只追加。`payload` 和 `sourceRefs` 存 JSON。

**Schema:** 在 `_migrations` 末尾追加一步，成功后 `user_version` 为 7。表：

- `research_cases(id TEXT PRIMARY KEY, project_id TEXT REFERENCES projects(id), question TEXT NOT NULL, method_commit TEXT NOT NULL, workflow_id TEXT, candidates TEXT NOT NULL, process_state TEXT NOT NULL, scientific_judgement TEXT NOT NULL)`
- `plan_versions(plan_id TEXT, version INTEGER, case_id TEXT REFERENCES research_cases(id), parent_version INTEGER, reason TEXT NOT NULL, branch TEXT NOT NULL, PRIMARY KEY(plan_id, version))`
- `execution_attempts(id TEXT PRIMARY KEY, case_id TEXT REFERENCES research_cases(id), plan_id TEXT NOT NULL, plan_version INTEGER NOT NULL, task_id TEXT, task_revision INTEGER, executor_id TEXT NOT NULL, process_status TEXT NOT NULL)`
- `case_events(id TEXT PRIMARY KEY, case_id TEXT REFERENCES research_cases(id), type TEXT NOT NULL, source_refs TEXT NOT NULL, payload TEXT NOT NULL, position INTEGER NOT NULL)`

对已有库：把 `workbench.sqlite` 复制到同目录的 `workbench.sqlite.bak-v6`，重新打开副本并确认 `user_version` 仍是 6，然后才执行这一步。副本打不开或版本不对就抛错并留下原文件。

- [ ] **Step 1: 写会失败的测试。** `caseCanHaveZeroCandidatesAndSkipStages`；`planChangeCreatesVersionWithReasonAndBranch`；`caseTimelineKeepsRejectedAndRestartedBranches`；`oldV5DatabaseUpgradesWithoutChangingExistingRows`；`currentV6DatabaseGainsCaseTablesWithoutChangingRows`；`attemptProcessStatusIsSeparateFromScientificJudgement`；`failedBackupAbortsMigration`。
- [ ] **Step 2: 运行** `flutter test test/case_store_test.dart`，预期因缺少 API 或迁移失败。
- [ ] **Step 3: 实现模型和仓库。** v5 夹具打开后要经过现有 v6 提纲迁移，再进入 v7；断言业务字段与迁移前一致，包括笔记、任务、运行、提纲和 `sections`。v6 夹具只增加四张空表，同样保持这些行的业务字段。科学判断不写入 `execution_attempts.process_status`。
- [ ] **Step 4: 运行** `flutter test test/case_store_test.dart test/core_test.dart`，预期通过。v5 夹具最终 `user_version` 为 7，不是 6。
- [ ] **Step 5: 只提交列出的路径。** `feat: record research cases and plan history`

### Task 3: Skill 只读映射与质量提示

**Files:** Modify `lib/core/research_skill.dart`, `lib/app/skill_panels.dart`; test `test/research_skill_test.dart`, `test/skill_ui_test.dart`, `test/skill_fixture.dart`.

**Interfaces:** `SkillReviewHint reviewHint(RevisionGroup group, String methodCommit)` 和 `List<SourceRef> decisiveNeighborRefs(ResearchEntry opportunity)`。提示含方法提交、严重程度、原因和 `needsReview`。函数返回新对象，不改 `ResearchEntry.data`。

提示规则：

- 方法提交是 V6.6 时，`searches` 行若有 `subq` 或 `intent` 就原样显示；没有就不编造。discovery-yield 只作为提示，不变成错误，也不改行内判决。
- `opportunities` 的 `decisive_neighbors: [{id, rev}]` 变成 `SourceRef` 列表。缺字段、类型不对的项忽略，不抛到界面上。
- 方法提交是 V6.6，而当前可行动机会（`continue` / `revise` / `ready`）没有 `decisive_neighbors`：保留该行原来的 `decision`，另给「按当前方法待复核」。
- 方法提交是 V6.4 时，不因为缺 V6.6 字段而标待复核。
- 未知公开字段在导入和 claim 草稿导出后仍然在。断言 skill 根目录没有被写入。

界面：在 `revisionBadges` 之外增加方法提示。现有「待复核」徽章继续表示行内审阅状态。新提示用单独文案，例如「按当前方法待复核」，避免两个状态看起来是同一个字段。

- [ ] **Step 1: 写会失败的测试。** 合成 V6.6 行保留 `searches.subq/intent`，discovery-yield 是提示，`decisive_neighbors` 能连到论文；V6.4 可行动行没有该字段时仍显示原判决；V6.6 可行动行缺字段时原判决还在，并出现「按当前方法待复核」；未知字段进出导入/导出仍在；测试前后 skill 根目录文件列表不变。
- [ ] **Step 2: 运行** `flutter test test/research_skill_test.dart test/skill_ui_test.dart`，预期新断言失败。
- [ ] **Step 3: 只做投影和徽章。** 不放宽现有校验，不从应用启动 `check-research.py`。草稿导出仍是 `needs_review`。
- [ ] **Step 4: 再跑这两个测试文件，预期通过。**
- [ ] **Step 5: 只提交列出的路径。** `feat: display versioned skill review hints`

### Task 4: 三个研究记录视图

**Files:** Create `lib/app/case_views.dart`; modify `lib/app/workbench_app.dart` 的 `overview()`（约 540 行）; test `test/case_views_test.dart`.

**Interfaces:** `CaseViews(store, caseId)` 读取 `CaseStore.caseTimeline(caseId)`。三个页签是关系地图、计划演进、执行记录。顶部是一行进度和下一动作，阶段文字只是展示。

入口：在概览「当前研究」卡片加「研究记录」按钮，推入 `CaseViews`。没有案例时，这个页面可以保存一个零候选案例，而不是把按钮禁用。不要往 `labels` 或手机底栏加项。现有 `relations_page.dart` 保持原样。

行为：

- 零候选、缺正文、跳步时，编辑和保存仍然可用。缺证据显示缺口和下一动作。
- 时间线同时留下否决、分叉、重启和原因。旧计划版本仍可见。
- 带来源的 AI 文本标成可修改建议。用户改建议不把建议写成事实，也不改 `scientificJudgement`。没有来源引用的 AI 文本保持未确认草稿。
- 执行记录 `processStatus == completed` 只表示这次技术运行结束。旁边不出现「科学结论成立」。科学判断只显示案例上单独保存的字段。
- 链接使用 `SourceRef` 的 kind、id、rev。找不到目标时显示缺引用，不按标题猜测。

- [ ] **Step 1: 写会失败的组件测试。** `zeroCandidatesAndMissingEvidenceDoNotDisableEditing`；`timelineShowsReasonForkRejectRestart`；`aiSuggestionShowsSourceAndCanBeEditedWithoutBecomingFact`；`attemptCompletedDoesNotShowScientificSuccess`。
- [ ] **Step 2: 运行** `flutter test test/case_views_test.dart`，预期失败。
- [ ] **Step 3: 实现三个页签和概览入口。** 桌面与手机都从概览进入。页签内容放在 `case_views.dart`，不要把三块界面写回 `workbench_app.dart`。
- [ ] **Step 4: 运行** `flutter test test/case_views_test.dart test/workbench_test.dart`。视图测试在 `Size(1280, 900)` 和 `Size(390, 844)` 都跑，预期通过。
- [ ] **Step 5: 只提交列出的路径。** `feat: visualize research relationships and evolution`

## 完成标准

- 任务 2 的 v5 和 v6 夹具升级后，旧笔记、任务、运行、提纲和分区还在，`user_version` 为 7，备份文件可打开。
- 任务 3 不改任何 `ResearchEntry.data`，也不改 skill 目录。
- 任务 4 不增加导航分区。零候选可以保存。技术完成不会显示成科学成功。
- `flutter analyze` 无问题。上述测试文件通过。不把这三步的通过写成任务 5–12 或三端原生验收已经完成。
