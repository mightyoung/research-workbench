# Research Workbench Implementation Plan

Goal: 可演示且持久化的科研文件交换业务闭环。
Architecture: Flutter 共享 UI；SQLite WorkbenchStore；本地资产快照；JSON/ZIP TaskSpec 与 ResultBundle。
Spec: docs/design.md。执行方法：本轮本机并行独立模块，集成者统一分析/测试/原生验证；已获授权，无需再次确认。

- [x] Core: models.dart / store.dart / exchange.dart；目录与 ZIP 研究导入、真实 JSONL 保留、任务和结果包、证据与报告；单元闭环验证。
- [x] Reader: reader_page.dart；Markdown 链接、本地 PDF 阅读组件、文献/主张元数据、定位笔记；widget 验证。
- [x] UI: main.dart / workbench_app.dart；概览、文库、任务编辑与导出、结果确认、写作提纲、研究关系；桌面和手机尺寸验证。
- [x] Verification: analyze、13 项 unit/widget 测试、真实研究快照只读导入、Android debug 构建与安装。
- [ ] Native acceptance: Android 系统弹窗妨碍原生 UI/文件选择器验收；本机缺完整 Xcode，Windows 需 Windows 开发机。
- [x] Delivery: 独立目录、README、协议/来源及许可声明、验证与平台边界记录。

核心检查：相对路径不越界；结果必须匹配存在的任务修订；包内指令不执行；原始研究状态不升级；导入快照不覆盖源数据。复杂故障专项暂缓。
