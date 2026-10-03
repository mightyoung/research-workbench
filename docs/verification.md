# 验证记录（2026-10-02）

## research-skill 集成第二期：再导入（2026-10-03）

分支 `feat/research-skill-reimport`。

- `flutter analyze`：无问题。`flutter test`：48 项通过。新增 `reimport_test.dart`（笔记迁移与待复核、未迁移笔记、提纲按修订迁移、日志被改写时提纲留在旧快照、目录→ZIP 路径匹配、人工绑定沿用、草稿带复核标记、未知目标项目在复制前拒绝）和 `reimport_ui_test.dart`（导入目标选择、未迁移笔记卡片、阅读器待复核与"标记已复核"）。v3 迁移测试夹具补上真实存在的 `entries` 表，并断言旧数据归入遗留快照后仍可见。
- 端到端：以 research-skill v6.5 的 `examples/v2-case/discover` 为第一轮、`update` 为第二轮。在第一轮的 `REPORT.md` 写笔记，并把提纲关联到 `[claims/c-recent@1]`；再把第二轮导入同一项目。结果：笔记迁移 1 条，因报告内容变化标为待复核；提纲仍指向 `c-recent@1`（最新为 r3，不自动改指向）；`c-recent` 显示 3 个修订；项目数保持 1。

## research-skill 集成第一期（2026-10-03）

分支 `feat/research-skill-integration`，参考 research-skill v6.5（`bd9e9d8`）。

- `flutter analyze`：无问题。`flutter test`：40 项通过（含 Codex 审查后的 3 项回归测试），新增 `research_skill_test.dart`（识别、过滤、修订、绑定、引用、回写草稿、报告引用）和 `skill_ui_test.dart`（桌面尺寸下的文库修订视图、论文绑定、引用链接、阅读器绑定卡片）。夹具为手写合成数据，结构对照 v6.5，未复制上游文件。
- 端到端：复制 v6.5 `examples/v2-case/update`，为其中 `p-recent-v1`（`9999.00004v1`）补一份合成 `paper.pdf` 和 arXiv 风格 `manifest.json` 后导入。绑定到 `p-recent-v1@2`，方法 `arxiv_manifest`，哈希一致。在该 PDF 上写一条笔记并导出草稿：
  - 草稿原样追加到 `research/claims.jsonl`，`check-research.py --strict-v2` 输出 FAIL（缺 `locator_reliability`、`supports_statement`、`scope`），符合"未补全不能冒充正式证据"的设计。
  - 人工补全 `locator.page`、`locator_reliability`、`supports_statement`、`scope` 后追加，输出 PASS；保留或移除 `workbench` 溯源字段、保留 `locator.pdf_page` 均通过。
- 未验收：PDF 原生渲染、Android/macOS/Windows 上的保存对话框。再导入同一项目属于第二期。

## 当前开发分支验证

源码验证基线：`feat/research-roundtrip` 的 `f641f81`（rebase 前为 `e888b17`）。下列原始日志均在本机被 Git 忽略的 `artifacts/final-2026-10-02/`，没有随仓库提交。

- `env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy flutter test --reporter expanded --concurrency=1`：27 项通过，见 `test.log`。去掉代理变量只影响本次命令，避免 Flutter 测试进程的本地 WebSocket 被代理截获。
- `flutter analyze`：无问题，见 `analyze.log`。
- `flutter build apk --debug`：完成，见 `android-build.log`。本地 APK 为 `build/app/outputs/flutter-apk/app-debug.apk`，SHA-256 `d70499c58cbf8cb226a59d3823bcdb27e897854e7ac18a7f03d3a11043eb5fbd`，见 `apk.sha256`。这是调试包，不是发布包。
- 测试覆盖任务包导入、人工执行记录、结果附件回传及校验、短期配对与单次 LAN 下载、页码引句到提纲/报告、显式关系图导航、同任务修订结果比较及手机/桌面控件。Android 原生文件选择器、PDF 渲染、LAN 实机传输仍需设备验收；源码测试和 APK 构建不等于这些原生交互已通过。

## 早期基线验证

- `flutter analyze`：目标仓库无问题，原始输出保存在本机忽略目录 `artifacts/analyze.log`。
- `flutter test --reporter expanded`：目标仓库 13 项通过，原始输出保存在 `artifacts/test.log`。覆盖目录/ZIP 快照与路径拒绝、任务/结果身份绑定、关系引用解析，以及桌面和手机尺寸下的阅读、笔记、任务修订、结果人工接纳、关系入口和提纲操作。测试使用合成资料。
- `flutter build apk --debug --target-platform android-arm64 --no-pub`：在与目标仓库源码一致的 `/tmp/research-workbench-stage` 临时构建副本中成功执行。原始输出保存在本机 `artifacts/android/build.log`，APK 已复制到 `artifacts/android/app-debug.apk`（145,372,079 字节，SHA-256 `36b9bd6abcf89a46e0163f02b041e3a120761ebe3117f0c6a6cc1e233cf8b8a9`）。这些文件被 Git 忽略，未上传远端。最终 APK 在本任务启动的 `Medium_Phone_API_36` 模拟器上 `adb install -r` 成功，安装原始输出保存在 `artifacts/android/install.log`；`am start` 成功，应用成为前台 Activity。真实截图 `artifacts/android/retry-before-action.png` 显示 Android **Digital Wellbeing isn't responding** 系统弹窗遮挡工作台。按后续授权，点选弹窗的 **Close app**，未清除数据；随即 `artifacts/android/retry-after-close.png` 显示 **Process system isn't responding**。此时停止模拟器操作。因此原生 UI、文件选择器、PDF 显示与文件往返仍未验收。APK 仅为开发调试产物，不是发布包。
- `tool/demo_import.dart` 使用本机私有研究目录验证了只读源导入；输入材料、快照与计数输出均留在本机，被 Git 忽略，不包含在发布仓库中。导入的实验计划不能视为已执行实验。

## 平台与功能边界

- 本机只有 Xcode Command Line Tools，`xcodebuild -version` 提示需要完整 Xcode；未完成 macOS 原生构建。Windows 原生构建需要 Windows 开发机。本轮没有提交或发布任何安装包。
- Android 构建/安装成功并不能证明原生文件选择器、PDF 渲染、导出目录写入已在设备端可用。这些仍需目标平台实机验收。
- Markdown 阅读、PDF 阅读组件、定位文字笔记及证据关联到 Markdown 提纲均已在源码实现；widget 测试覆盖 Markdown/笔记和提纲关联，PDF 真机渲染未验收。笔记存放于 SQLite，不写进 PDF；导出的报告是附来源记录的 Markdown 草稿，不是完成排版、引用样式与投稿检查的论文。
- 文件包可通过任何人工文件传输渠道送往异网设备；当前应用提供用户显式开启、短期配对、单文件的 LAN 传输；不提供后台同步、云同步或远程自动执行。任务包中的代码/数据引用是描述字段，具体文件、版本、环境、许可证和实验可重复性由执行方核验。
- 结果导入先保留为未接纳运行；“接纳为证据”是用户操作，不对科学真实性作自动判断。原始 JSONL 字段及状态保留，缺失或多义的关系不自动推断。
- 导入资料复制到应用私有目录。应用尚无用户级 ACL、加密库或协作权限模型；不要把这版当作多用户服务器。
