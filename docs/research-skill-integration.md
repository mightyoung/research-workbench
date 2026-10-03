# research-skill 集成设计

参考版本：research-skill **v6.5**（tag `v6.5`，提交 `bd9e9d8`）。以下引用的格式、路径和规则均以该版本的 `SKILL.md`、`references/evidence-schema.md`、`references/acquisition.md`、`scripts/init_project.py`、`scripts/fetch_paper.py`、`scripts/acquire.py` 为准。v6.5 之后的提交不纳入。

## 1. 目标与原则

目标闭环：research-skill 检索分析 → 工作台导入阅读、精读、编辑 → 精读结果以 research-skill 能接收的格式回流 → research-skill 校验后继续 discover / update / review。

原则：

1. **research-skill 是格式的唯一权威。** 工作台不另定一套研究记录格式，只读取它的 V2 日志，并按它的格式起草回写行。本设计落地时，同步修改 [design.md](design.md) 中"未复制其他项目 schema"一句，改为"以 research-skill V2 为外部交换格式"。
2. **工作台不直接写 research-skill 的 `research/*.jsonl`。** 回写只产出待审草稿，由人或 agent 审核、补全后按"追加下一 rev"的规则写入，再运行 `check-research.py`。这和"导入快照不覆盖源数据"一致，也符合 research-skill"迁移不自动补真"的要求。
3. **不升级任何状态。** 在工作台打开 PDF、写笔记，都不改变论文的 `reading_depth`、记录的 `review_status` 或机会的 `status`。回写草稿一律 `review_status: needs_review`。
4. **工作台不需要识别也能用。** 普通研究目录照旧导入；识别为 research-skill 项目时才启用下面的增强。

## 2. 项目识别

导入时，若快照根目录存在 `research/papers.jsonl`、`research/claims.jsonl`、`research/sources.jsonl`、`research/opportunities.jsonl`（v6.5 的四个基础日志），就把项目标为 `research-skill`。有任一行 `schema_version: 2` 时记为 V2，否则记为 V1 兼容（只显示，不做第 5、7 节）。

## 3. 导入过滤

research-skill 项目里有大体积、与阅读无关的内容，会撞上现有的 30 MiB 单文件 / 150 MiB / 10,000 文件限制。识别为 research-skill 项目时，快照阶段跳过下列路径（对照 v6.5 `init_project.py` 写入的 `.gitignore`，但保留 `related_work/` 下的论文本体）：

| 跳过 | 原因 |
|---|---|
| `related_work/*/versions/*/source/**` | arXiv TeX 源码包、解压及清洗副本 |
| `related_work/**/.stage-*`、`related_work/**/.fetch.lock` | 下载中间产物、锁文件 |
| `DataSet/**`、`experiment/**/checkpoints/**`、`**/*.pt` | 数据与模型权重 |
| `__pycache__/**`、`.shot-tmp/**`、`.git/**` | 临时文件、版本库 |

保留：`related_work/<slug>/versions/vN/paper.pdf` 及其 `manifest.json`、`related_work/acquired/**/material.{pdf,xml,html}` 及其 `manifest.json`、根目录和 `experiment/` 下的 Markdown、`research/*.jsonl`。

导入完成后显示跳过的文件数和总字节数，不静默丢弃。过滤后若仍超限，照旧报错。

## 4. 记录类型与修订视图

**类型**：识别的 kind 由 4 种扩展为 v6.5 的全部 9 种日志：`sources`、`papers`、`claims`、`opportunities`、`searches`、`tensions`、`experiments`、`failures`、`handoffs`。其余 JSONL 仍归为 `other`。

**修订**：v6.5 规定日志是追加历史，同 ID 的最新一行代表当前状态，依赖固定在 `ID + rev`。

- 每条导入记录额外保存来源 ID（`data.id`）和修订号（`data.rev`），原始 JSON 仍完整保留。
- 文库列表默认按 `(kind, id)` 分组，只显示 `rev` 最大的那一行；旧修订折叠在详情页的"修订历史"里。
- 最新行为 `active: false` 时视为已退役，默认隐藏，可通过筛选显示。
- 最新行为 `review_status: needs_review`（机会看 `status: needs_review`）时显示"待复核"标记。
- 研究关系图保持现有行为：按引用里写明的 `id + rev` 精确解析，不自动换成最新版；若被引修订已不是最新，额外显示"有更新修订"。
- 同一 `(kind, id, rev)` 出现多行属于日志错误：全部保留，标"修订重复"，不擅自选一行。

## 5. 论文与材料文件绑定

v6.5 有两条获取路径，按优先级尝试，结果存入绑定表：

1. **`material_binding`（`acquire.py` 登记的通用获取）**：`papers.source_id + source_rev` → 对应 source 行的 `material_binding.path`（相对项目根）→ 匹配快照中同路径的文档。
2. **arXiv 下载（`fetch-paper.sh`）**：遍历 `related_work/<slug>/versions/vN/manifest.json`。manifest 里的 `arxiv_id` 带版本（如 `2301.11305v1`），论文行的 `arxiv_id` 不带 vN、版本另存于 `version`，因此按 `paper.arxiv_id + paper.version == manifest.arxiv_id` 匹配，并把同目录的 `paper.pdf` 绑定到该论文。

每条绑定都核对 SHA-256：`material_binding.sha256`，或 `manifest.json` 里 `sha256["paper.pdf"]`。不一致时仍然绑定，但标"文件与登记哈希不符"，回写草稿里也带上这个标记。一份文档能匹配到多篇论文，或一篇论文能匹配到多份文档时，都不自动绑定，列为"待人工选择"。绑定对象是论文的 `id + rev`（取导入时的最新修订）。

界面效果：

- 阅读器顶部显示绑定的论文：标题、`arxiv_id` + 版本、`publication_status`、`reading_depth`，以及"阅读不升级阅读深度"的提示。
- 论文详情页可以直接打开绑定的 PDF，显示该论文现有的 claims，以及工作台里对应的精读笔记。

## 6. 交付物引用跳转

v6.5 要求根目录的 `*.md` 和 `experiment/*.md` 用 `[kind/id@rev]` 引用日志记录，例如 `[claims/c3@2]`。Markdown 阅读器把这种文本渲染成可点击链接，点开即对应记录的详情（精确到该 rev）；解析不到的标为未解析，不猜测。

写作提纲导出 Markdown 报告时，引用 research-skill 记录的位置也写成 `[kind/id@rev]`，这样报告放回项目后可以直接被 `check-research.py` 检查引用新鲜度。

## 7. 回写包：精读笔记 → claims 草稿

**入口**：项目页的"导出回写草稿"。用户勾选笔记，只有所在文档已绑定论文的笔记可选；未绑定的列出原因并跳过。

**产物**：单个 UTF-8 文件 `workbench-claims-<UTC时间戳>.jsonl`，通过系统保存对话框保存。每行一个完整 V2 claim 对象，不写增量。建议放在项目根的 `workbench-drafts/` 下，不放进 `research/`，避免被当成正式日志校验。

**字段映射**：

| 字段 | 取值 | 由谁补全 |
|---|---|---|
| `schema_version` | `2` | — |
| `id` / `rev` | `c-wb-<8 位随机十六进制>` / `1`（见待确认 2） | 追加方确认无冲突 |
| `updated_at` | 导出时刻，UTC，含时区 | — |
| `paper_id` / `paper_rev` | 绑定论文的 `id` / `rev` | — |
| `statement` | 笔记正文 | 可修改 |
| `basis` | `full_text`（可选值只有 abstract / full_text；页码定位要求 full_text） | — |
| `locator` | `{version: 论文 version, pdf_page: 笔记页码, page: null}` | 核对纸本页码后填 `page`（见待确认 1） |
| `locator_reliability` | 填了 `page` 为 `page`，否则 `null` | 人 |
| `evidence_kind` | `null`（见待确认 3） | 人：paper_statement / inference / hypothesis |
| `supports_statement` | `null` | 人 |
| `does_not_support` | `[]`（v6.5 要求非空） | 人 |
| `scope` | `null`（要求 data/scale/evaluation/method_version） | 人 |
| `conflicts` | `[]` | 可补 |
| `text_binding` | 只对 Markdown/文本文档且引句是原文精确子串时生成：`{path: 相对项目根, sha256: 原始字节, excerpt: 引句}`。PDF 不生成，因为 v6.5 不做 PDF 文本提取 | — |
| `material_access` | 有 `text_binding` 为 `available`，否则 `unchecked` | — |
| `review_status` | `needs_review` | 审核后改 |
| `workbench` | `{note_id, document_path, document_sha256, hash_mismatch, quote, pdf_page, exported_at, app_version}` 溯源信息 | 追加方可保留或移除 |

**有意不自动填的**：`evidence_kind`、`supports_statement`、`does_not_support`、`scope`、纸本 `page` 都是科学判断或需要人工核对的内容。草稿原样追加会被 `check-research.py --strict-v2` 拒绝，这是有意的，防止未经审查的笔记冒充正式证据。

**导出摘要**（导出后在界面显示）：导出条数、跳过条数及原因、哈希不符的条数、待人工补全的字段清单。

**研究 agent 侧的接收**：按 research-skill 现有规则进行，读草稿 → 补全 → 追加 → 运行 `check-research.py`，v6.5 不需要改动。以后可以在 research-skill 增加一个导入草稿的辅助脚本，不在本次范围内。

## 8. 再导入同一项目（已实现，与原设计不同处见下）

research-skill 会反复运行，工作台需要在不丢失笔记和提纲的前提下接收新一轮结果。

- 导入时由用户明确选择"新建项目"或"更新已有项目 X"（同名项目排前），不靠目录名猜测。
- 每次导入复制为新快照，旧快照不删除。未引入 `snapshots` 表：记录和文档在原行上更新，本地 ID 不变。
- **记录**：按 `(kind, id, rev)`（无 id 时按键序无关的内容哈希）对应旧行并沿用本地 ID，提纲、笔记关联因此不断。被提纲、笔记或"从实验计划生成的任务"引用的记录：同一修订内容改变时拒绝导入（要求追加新修订）；来源中消失时保留。旧版本以 `other` 保存的 sources/searches/tensions/failures/handoffs 在唯一匹配时原地改类。
- **文档 / 笔记**：同路径文档沿用原行；若内容改变且原文档有精读笔记，保留旧版本（笔记仍对应写它时的字节），新内容另成一个版本，文库标"旧版本（保留精读笔记）"，默认打开流程用最新版本。与原设计"跟过去并标待复核"不同。
- **防误操作**：没有任何文档或 JSONL 记录、或选中的是任务/结果包时拒绝更新，不进入清理。
- 论文绑定在新快照上重新计算。

## 9. 数据库变更

在 `WorkbenchStore._migrations` 末尾追加，不改已发布的迁移：

- 第一期（迁移 5）：`projects.layout`（`generic` / `research-skill-v1` / `research-skill-v2`）；`documents.sha256`；新表 `paper_bindings(document_id, paper_source_id, paper_rev, method, hash_ok)`。修订分组在 Dart 侧计算，不加列。
- 迁移 6：`notes.entry_id`（笔记关联研究记录）；新表 `sections`（提纲段落：标题、层级、顺序、论述、证据支持程度），`outline.section_id`；已有提纲按标题归并成段落。第 8 节的再导入不需要新表。

## 10. 测试

为避免复制 research-skill（Apache-2.0）的文件，测试夹具在测试代码里手写，结构对照 v6.5：

- 导入：识别为 V2；9 种 kind 归类正确；同 ID 多修订只显示最新一条；`active: false` 默认隐藏；重复修订被标出。
- 过滤：`source/`、`DataSet/`、`.pt` 被跳过并计入摘要；`paper.pdf` 和 `manifest.json` 保留。
- 绑定：arXiv manifest 匹配、`material_binding` 匹配、哈希不符被标记、多对多不自动绑定。
- 引用：`[claims/c1@2]` 解析到正确修订；不存在的引用标为未解析。
- 回写：未绑定笔记被跳过；字段映射正确；Markdown 引句精确匹配时生成 `text_binding`，PDF 不生成；输出每行都是合法 JSON。
- 端到端（手动一次，结果记录到 [verification.md](verification.md)）：用 research-skill v6.5 的 `examples/v2-case/update` 导入工作台，导出回写草稿，人工补全后追加到该示例的副本里，运行 `check-research.py --strict-v2` 通过。

## 11. 不做

- 在工作台里编辑或追加 research-skill 日志（机会状态、claim 修订等），这些都经由 research-skill 进行。
- `searches`、`tensions` 的专门视图，第一期只在通用详情页显示原始字段。
- PDF 文本提取或引句的自动核验。
- 自动发现或同步 research-skill 项目目录。

## 12. 实验计划与运行结果互通（已实现）

- 计划阶段的 `experiments` 记录可"生成实验任务"，任务规格固定 `source: {kind, id, rev}`。
- 运行结束后可单独记录研究结论（支持 / 反驳 / 无定论、能否区分解释、理由、花费），规则与 `check-research.py` 一致；与执行状态、证据接纳分开。
- "导出给 research-workflow"生成一行 `phase: executed` 的 `experiments` 记录（`plan_ref`、`actual`），由人追加进 `research/experiments.jsonl`；工作台不直接写 `research/`。内容变化的再导出递增 `rev`。
- 未覆盖：计划上的 `approval` 与运行的 `provenance`（代码提交、命令、输出哈希），`--strict-v2` 下仍会被拒绝。

## 13. 已确认的决定（2026-10-03）

1. 页码：草稿只填 `pdf_page`，`page` 留空由人确认。
2. 草稿 ID：工作台生成 `c-wb-<8 位十六进制>`，追加方确认不冲突。
3. 笔记界面：文档已绑定论文时，提供"证据类型"和"不支持的更强结论"两个可选输入。
4. 分期：第 2–8、10、12 节已实现。
