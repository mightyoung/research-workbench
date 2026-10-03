# Research Skill × Workbench：研究案例与执行契约融合设计

日期：2026-10-03。状态：用户已批准进入实施计划；产品代码实施尚待计划审阅与执行方式选择。本文定义现有 research-workbench 的科研业务契约，不触发生产技术栈迁移，不引入 Flowable/Activiti。

**2026-10-03 用户决策（优先于下文较早的“关卡/阶段”措辞）：**总体研究流程用于可视化、分析和留痕，不强制阶段顺序、审批或证据齐备才允许探索与改变研究方向。`WorkflowDefinition` 只是可选路径模板与提示。界面提供对象关系研究地图、计划演进时间线（改变理由、分叉、否决、重启）和具体任务执行记录；AI 对矛盾、缺口、下一步的分析须附来源、标作可修改建议，不作为确认事实。原 research-skill 或导入项目自己的校验/质量结论忠实显示为警示或评估状态，不由工作台强制科研流程，也不改独立 skill。真实命令执行授权、数据外传确认、包 schema/文件完整性、同 ID 冲突与未知执行状态仍是技术安全边界。

## 1. 目标、范围与先后关系

让 `research-skill` 的方法纪律和 `research-workbench` 的阅读、任务、结果、报告在**一个可追溯 ResearchCase** 中衔接，同时保留 skill 脱离应用独立使用。首个闭环是：领域地图 → 生成并筛选多个候选 → 针对决定性近邻精读正文并按需核代码/数据 → 核验一个强基线 → 做一个有区分力的最小实验 → 基于证据明确继续、调整或停止。允许零个可行方向、负结果和复现失败；不承诺原创、发表或实验必然有辨别力。业务完整性由关键证据、未知和决定的可追溯性判断，而非文件数量或表单填满率。

本规格接在[阅读升级规格](2026-10-03-research-reading-upgrade-design.md)之后：第一阶段的原文定位证据卡、OCR/区域摘录与项目搜索为案例提供更好的证据入口；融合案例可先使用现有笔记和 skill JSONL，不强制等 OCR 完成。阅读规格第二阶段的跨论文比较使用同一 `ResearchCase`/证据关系，不建第二套候选和比较库。跨设备回传前须处理阅读规格已记录的同机结果包冲突回归。当前只在既有 Flutter 工作台规划增量实施；Flutter/Tauri 探针是未来外壳参考，不构成生产迁移决策。

## 2. 真实基线与差距

**方法侧当前基线与来源。** `/Users/muyi/Downloads/dev/research-skill` 的工作区在本次只读核对时无未提交变更，分支为 `main...origin/main`，HEAD `b09f09499dd2ac64317dd1291532e5aac562fae8` 标记 `v6.6`；`UPSTREAM.json` 写 `local_revision: 2026-10-03-v6.6-discovery-yield`、`local_schema_version: 2`，并注明上游来源固定在 `skJack/research-workflow@14c882df...`。这些只说明仓库记录的来源和当前版本，不推断是谁在何时修改了用户项目。仓库没有 `v6.4` tag，历史 V6.4 的明确合并提交为 `03f768c8526fb9d9c1d31ae808b36c5e17e77c25`。本设计以**当前 V6.6** `SKILL.md`、`references/evidence-schema.md`、`references/field-discovery.md`、`scripts/check-research.py`、`scripts/research_v2.py` 为默认方法契约，并用 `git show 03f768c:<path>` 核对 V6.4 历史输入。两者继续使用 `schema_version:2` 的四个基本日志 `sources/papers/claims/opportunities.jsonl` 和五个扩展日志 `searches/tensions/experiments/failures/handoffs.jsonl`；`research-brief.md`、`landscape.md`、`opportunities.md`、按需 `paper-reading.md`、`experiment/results.md`、`experiment/evaluation.md`、`handoff.md` 承载可读判断。JSONL 追加完整快照，引用身份为 `kind/id@rev`。计划/实测分别用 `experiments.phase=planned/executed`；严格 V2 对已执行计划的人工 approval、已完成实测的 provenance 有结构要求。`actual.provenance` 声明代码 commit、命令、环境文件哈希和输出哈希；校验器不验证科研判断或真实执行。`failures` 保留技术/判别力/假设/资源失败；`handoffs` 绑定输入/输出 SHA-256，摘要不等于完成。Skill 不能被工作台导入包当作可执行指令。

**V6.4 → 当前 V6.6 的相关增量。** V6.5 在 `searches` 增加可选 `subq`；V6.6 的当前 schema 又增加可选 `intent=known_item/exploratory/snowball`。当前校验器据检索意图、引用追溯和浅阅读比例给 `discovery yield` 提示，这类提示不自动判失败。V6.6 方法指导在 discover 且需要选题时先生成 5–8 个原始想法、覆盖至少 3 种贡献类型，再筛选；最终仍可零个可行方向，但停放项应写可执行化路径与最近可做的构造动作。这是方法指导，不是要求工作台为每个想法强制填表。V6.6 的 `opportunities.decisive_neighbors:[{id,rev}]` 引用论文：当前有效的 continue/revise 或 ready 记录若缺字段，默认校验提示、`--strict-v2` 报错；若引用的论文仅 metadata/abstract 而未达到 `targeted_body/full_text`，默认和严格模式都报错。`scripts/research_v2.py` 只对当前有效修订应用该门槛。V6.4 历史行必须原样保留并可阅读；在当前严格规则下不合格的可行动结论标待复核，实际读正文后**追加**新修订和近邻引用，不回填或覆盖旧行，不把格式校验当科学证明。两版本没有因此改成新的 JSONL 日志种类或实验执行格式。

**应用侧现状。** `research-workbench/lib/core/exchange.dart` 已把研究目录/ZIP 快照导入私有目录，解析 JSONL 为通用 `ResearchEntry` 并保留源字段；`lib/core/research_skill.dart` 当前以 V6.5 布局识别九种日志、显示修订与论文材料绑定，并产出需人工补全的 claim 草稿，因此能保留 V6.6 新字段，但尚无针对 `intent`、`subq`、`decisive_neighbors` 或 discovery-yield 的业务判断界面。`lib/core/store.dart` 已有项目、文档、条目、笔记、提纲、任务 `(id,revision)`、运行 `runId`、结果接纳状态和快照。`ResearchExchange` 已有带 SHA-256 manifest 的 `research-task-v1`/`research-result-v1` 包；任务命令只存为数据，结果导入先待接纳，界面可横向比较同任务修订的运行。`lib/core/lan_transfer.dart` 是显式启动的同网单文件传输；不同网络仍靠人工文件交换。

**缺口。** 当前 skill 行是保真导入记录，未成为可编辑的 `ResearchCase`、`PlanVersion` 或执行授权；应用任务和运行未显式引用 `kind/id@rev`、方法版本、候选判决、数据划分、代码提交/环境哈希或执行者；计划与实测不能自动视为 skill 的 `experiments` 行。没有统一平台任务/消息/对象存储/OCR/RAG 服务接入，也没有离线执行状态的协调器。已实测的本地结果包回导冲突和本地手工运行无法接纳，见阅读升级规格 §5；不能把单手机比对当作远端执行已验证。

| 当前 V6.6 对象/纪律（兼容 V6.4 历史输入） | 当前工作台映射 | 缺少的桥接 |
|---|---|---|
| `papers/claims` + 正文定位与修订 | 导入条目、材料绑定、笔记草稿 | 原文证据卡与案例级引用、复审状态 |
| `opportunities` 的多候选与 continue/revise/park/abandon | 通用条目显示 | 候选池、筛选记录、零可行方向状态 |
| `experiments` 计划、approval、实测 provenance | 泛用 task revision/run JSON | PlanVersion、授权与尝试、来源和判断回写草稿 |
| `failures/handoffs` | 通用条目显示 | 失败条件、重开条件、设备移交状态与哈希核对 |
| A/B/C 报告、`[kind/id@rev]` | Markdown 报告与提纲 | 报告中的案例决策链和引用完整性检查 |

## 3. 四层对象：方法、模板、案例、尝试

1. **MethodSpec（有版本的方法规范）。** `methodId`、`methodVersion`、来源仓库与不可变 commit、适用场景、证据/评审规则和引用链接。新案例默认登记当前 `research-workflow@b09f094`（V6.6）；导入旧案例可保留 `research-workflow@03f768c`（V6.4），不暗中升级既有案例或旧 JSONL 判决。两版同为 JSONL schema v2，方法版本与行 schema 版本分开；需要按当前方法复核时追加新修订。MethodSpec 是指导和校验依据，不承载用户研究结果；skill 继续独立运行。
2. **WorkflowDefinition（可选的轻量模板）。** `workflowId/version`、建议节点和可参考的证据/未解决问题。默认模板可表达“地图→候选→决定性近邻→基线→最小实验→判断”，但不是执行引擎、流程锁或审批表。研究者可跳步、分叉、停放、回退、否决、重启或只阅读；任何研究质量规则均以警示/评估状态留痕，不阻止保存或探索。真实执行与外传另受技术授权约束。
3. **ResearchCase 与 PlanVersion。** Case 有稳定 `caseId`、项目/问题边界、MethodSpec 引用、可选 WorkflowDefinition 引用、多个候选及各自 `kind/id@rev`、当前决定和待核事项。可有零个可行候选；“无方向”是合法结论。PlanVersion 是案例中一次明确的可检验计划快照：`planId+version`、目标候选/反证、强基线、预测与竞争解释、数据与划分、指标/单位/不确定性、预算、停止条件、证据引用、批准范围。计划更改只增版本，旧版本不覆盖；不同于 skill JSONL 的 `rev`，也不同于工作台 task revision，三者通过显式 crosswalk 关联。
4. **ExecutionAttempt（一次被授权的执行尝试）。** `attemptId`、`caseId`、`planId+version`、对应 workbench `taskId+revision`、唯一指定执行者/设备、授权人/时间/范围、派发包哈希、接收/启动/心跳/结果时间、状态、`runId`、代码 commit、数据 manifest/split、环境哈希、参数/命令、日志与产物哈希。一次 plan 可有多个 attempt，但每个 attempt 不换执行者；需要换人或重试时显式新建 attempt，并先核原 attempt 的实际状态与副作用。执行记录 `completed` 仅指一次技术运行完成，不表示基线公平、假设成立或论文结果可用。

对象关系：`MethodSpec` 约束一个或多个 `ResearchCase`；可选 `WorkflowDefinition` 提供界面提示；`ResearchCase` 有候选与多个 `PlanVersion`；一个 `PlanVersion` 可派生多个 `ExecutionAttempt`，每个 Attempt 至多指向一个 workbench run。所有外部 skill 证据用 `(sourceProjectSnapshot, kind, sourceId, rev)`，所有原始文件另绑 SHA-256；不能仅用标题匹配。案例的 `processState`（例如探索中、等待材料、计划待批准、执行中、等待回传、已结案）与 `scientificJudgement`（证据不足、支持特定条件、反驳、结果不具辨别力、技术失败、停止/待复审）分开保存和展示。业务完整性由关键问题与竞争解释、决定性近邻/基线证据、可追溯计划、真实执行记录及明确的未知/失败/下一动作支撑；没有运行也可合规结案为“停止/无可行方向”，不能假装成功。

## 4. 首个闭环的用户流程

1. **建案例与领域地图。** 用户给问题边界、任务/判断时点、资源上限；默认读取当前 V6.6，也可保真导入 V6.4 历史 `research-brief/landscape` 与九类 JSONL，并在案例上记录来源方法 commit。保留 A 阅读路线、B 问题/方法/证据地图；检索记录若有 `subq/intent` 就展示，缺失不臆造。缺乏经典任务定义或真实来源时标待核，不阻断低风险阅读。
2. **生成并筛选候选。** 对 discover 且需要选题的案例，按当前 V6.6 方法提示先生成多样候选池（建议 5–8 个原始想法、至少 3 种贡献类型），再逐项反证、筛选；review 模式只审给定主张，不强求候选池。记录最强反证、最近似工作、数据可用/需标注/需构造测量/待核实、硬关卡与改变决定的条件。用户可只保留阅读/数据探查，最终可零个可行方向；停放项给可执行化路径或说明为何无合法下一动作。退役和负结果保持可见，不把建议数量做成阻止保存的表单门槛。
3. **关键近邻精读。** 用同一阅读证据卡回到 PDF 页/图表与文档哈希；`reading_scope` 写实际读过的章节和未读范围，按当前决定需要追到论文版本、代码固定 commit、数据协议/划分、配置与关键结果。当前 V6.6 的 continue/revise/ready 在独立 skill 严格校验中需要 `decisive_neighbors` 及实际正文阅读；工作台如实显示该校验要求和缺口，不强制把候选改成 park 或阻止继续探索，也不为过校验挑已读论文凑数。V6.4 历史候选缺此字段时仍显示原始判决，但不可悄然宣称符合 V6.6 严格校验。若缺代码或数据，标未知对哪项判断的影响，不自动宣称论文无效或复现失败。手机适合阅读、摘录、审阅与移交批准，不默认跑外部论文代码。
4. **一个强基线与最小实验。** 基线先核信息、数据划分、评测和调参预算是否可比。PlanVersion 写对立预测、能区分的条件和最小预算；无可测真值或无合法数据时停放。明确授权后，选定单一执行者，把任务规格/材料清单送到执行设备；设备自行在可信环境中启动已批准的命令。工作台导入包只能解析/展示/记录，绝不自动执行脚本。
5. **结果、判断、交接。** 接收原始 result 包后核 manifest、`attemptId`/task revision、代码/数据/环境/日志/产物哈希，先待接纳；人工确认真实范围后才关联研究证据。记录 `supporting/refuting/inconclusive` 与技术失败、泄漏/偏差疑点、负结果及重开条件。选择继续、调整或停止，报告保留 `[kind/id@rev]` 和本地证据来源。向 skill 回流的是待审的完整追加修订草稿，人/agent 按案例固定 MethodSpec 版本审阅；若要按**当前 V6.6** `check-research.py --strict-v2` 通过，历史 V6.4 的可行动机会还须实际补读决定性近邻并追加新修订。应用不直接覆盖 `research/*.jsonl`。

## 5. 最小交换与平台接口

**兼容优先。** 保持现有 `research-package-v1` manifest、`research-task-v1` 和 `research-result-v1` 的基本导入；在明确版本的新包/扩展字段中增加 `caseRef`、`methodRef`、`planRef`、`attemptId`、`executorId`、`approvalRef`、`inputManifest`。旧包仍能导入为“未关联案例的任务/结果”，需人工补关联，不伪造 provenance。当前任务导出 manifest 只列 `task.json`，README 与结果模板是辅助文件；新增会影响决定或执行的 `case-context`/数据文件必须逐项列入 manifest 并校验，未列入者不得提供业务输入。导入事务先验证格式/路径/哈希/大小与任务修订，再保留原包；同 ID 同业务内容重复导入应幂等，真正不同内容应冲突而不覆盖。可回流 skill 的 JSONL 与应用内部对象分开；`schema_version:2` 是 skill 行版本，不能充当应用包版本或 MethodSpec 版本。

派发所需的最小信息是：任务/计划/尝试身份与版本、唯一执行者、授权范围和预算、代码仓库与固定 commit、命令及参数、环境锁定文件/哈希、数据来源/许可/manifest/训练验证测试划分与文件哈希、评测单位/指标和停止条件。包可只携带引用，执行端须确认实际文件与哈希；需要传输字节时由用户明确选入且不得夹带凭证。回传至少含原 attempt 和 task revision、开始/结束/未知状态、实际代码/环境/数据版本、日志、原始指标/产物及 SHA-256、偏离计划与未完成原因。`result=completed` 不是科学判定，`accepted` 是人工审阅状态。

**掉线与副作用。** 一个任务修订/尝试只有一个指定执行者，分派动作记录幂等键；网络中断后状态标 `unknown`，先用执行端回执、任务日志或人工核对是否已启动/产生副作用。无确认时不自动重派、重跑或“恰好一次”承诺；显式新 attempt 才可重新授权。LAN 只服务当前同网显式单文件会话；不同网络支持带 manifest/hash 的人工文件导出导入，不承诺无中继自动穿透、后台同步或设备在线推送。

**未来统一平台。** 当前 app 用本地适配器实现 `ResearchCaseStore`、`ObjectRefStore`、`TaskDispatchPort`、`MessagePort`、`OcrPort`、`RagContextPort` 的最小接口；无统一平台时功能不降级。平台建成后，基础平台拥有实际文件/结构化对象存储、数据中心、任务/消息、包/多端/LAN 交换和应用命名空间；研究应用注册领域 schema、业务命令、证据及授权规则，并按项目/证据范围向 AI 提供与 UI 一致的读取和写入契约。接口平台负责第三方连接器、映射、验证和交换任务，基础平台持久化其记录。OCR/RAG 是可选公共能力，来源与权限仍由科研业务校验。这里不决定 Obsidian、向量库、缓存新框架或技术栈迁移，亦不把“各应用永久自持数据库”定为最终架构。ClaudeScience/OpenScience 仅为可参考线索，OpenScience 身份尚未核定，不作为依赖或格式来源。

## 6. 阶段范围与首轮验收

**阶段 A（最小融合闭环）：** 默认登记当前 V6.6 MethodSpec，兼容 V6.4 历史输入；建立案例/候选/计划/尝试 crosswalk；读取现有九类日志与 claim 草稿导出，并显示 `subq/intent`、决定性近邻及发现质量提示的来源/状态；任务/结果包加可选关联字段；完成同机回导幂等修复；一个执行者的离线移交/回收与人工审阅；案例级证据报告。先用现有笔记和 PDF 页定位，阅读升级第一阶段完成后换用证据卡。无流程引擎、自动代码执行、自动跨网穿透或统一平台迁建。

**阶段 B：** 接入阅读规格的跨论文问题比较；多次计划/运行、负结果与重开条件；平台任务/消息/对象/OCR/RAG 适配可逐项替换本地实现。**阶段 C：** 依据另行审阅的统一外壳和技术栈方案迁移数据所有权与多端交换；本规格不触发该迁移。

首轮使用全部合成材料验收，至少覆盖研究地图、计划演进时间线和执行记录三个视图；零候选、缺少正文与跳步均可保存，质量提示不锁操作。其余至少覆盖：

- 当前 V6.6 固定提交与 V6.4 历史提交的九类日志均可保真导入，原始未知字段、`kind/id@rev` 与文档哈希保留；旧 continue/revise/ready 行缺 `decisive_neighbors` 时显示原判决和“按当前方法待复核”，不自动补造全文阅读。`intent/subq` 可选，discovery-yield 提示不变成错误。Skill 脱离工作台可独立使用；应用不调用或改写其运行文件。
- 一个领域地图形成多个候选，最终分别演练保留一个、零个可行方向、近邻正文不可得但继续探索并显示质量警示；各结果有引用、未知和后续动作，无候选数量硬门槛。
- 一个基线和最小实验含计划批准、固定代码/数据划分/环境、单执行者、真实 attempt 回执；未批准包不能被标“可执行”，手机导入不执行命令。执行失败与低辨别力阴性分别进入不同判断；流程结束不能自动显示科学结论成立。
- 两台实际安装实例之间用合成任务包/结果包完成首次回传、人工接纳、引用报告；同机重复导入保持幂等、不同内容同 ID 拒绝。拔网且执行状态未知时不自动重跑；不同网络只测试人工文件交换，不声称自动直连。Android、macOS、Windows 的独立运行/文件选择另按阅读规格验收，单手机不能替代。
- 追加给 skill 的草稿先标 `needs_review`，人工补齐批准、实际 provenance 与引用后由独立校验流程验证结构；PASS 只代表格式与声明依赖可核，不宣称科学真实性。

## 7. 已获用户确认的设计决定

1. 第一版界面用简洁阶段进度作可视化入口，突出证据缺口与下一步；阶段仅提示，不能锁定科研操作。三个主视图为关系地图、演进时间线、任务执行记录。
2. 阶段 A 对“执行授权”的记录方式：建议由明确的人名/设备、时间、范围与包哈希组成，移动端可审阅批准；正式身份认证和远端角色 ACL 留给统一平台设计。需要跨团队审签时再追加规则。
3. Skill 回写建议始终生成待审 JSONL 草稿，由现有独立 `check-research.py` 和人工/agent 追加；不在应用内自动改源日志。若未来需要应用代写，再单独设计冲突和版本审查。

两份规格已获准进入实施计划；计划经审阅并选定执行方式后再实施产品代码。本阶段不修改 skill、应用运行逻辑或平台工程。
