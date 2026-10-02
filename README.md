# 研究工作台 Research Workbench

面向 Android、macOS 和 Windows 的本地科研工作台。它将研究材料保存为独立快照，支持阅读、记录、整理研究关系、准备离线实验任务、接收运行结果并生成 Markdown 写作草稿。应用不自动执行任务中的命令，也不会将材料上传到云端。

## 目前可用的流程

1. 在“概览”导入研究目录或 ZIP。应用复制原文件到自己的资料库，识别 Markdown、PDF 和 JSONL；原目录保持不变。手机通常使用 ZIP 导入更方便。
2. 在“文库与证据”查看论文、主张、候选和实验条目，打开 Markdown/PDF 并保存定位笔记。在“研究关系”查看条目间可解析的引用。
3. 在“研究任务”编辑任务目标和 JSON 规格，保存修订，导出离线任务 ZIP。规格可记录参数、数据引用、代码版本、环境、预期产物和执行命令。
4. 将任务包带到另一台设备，人工取得并核对所需代码、数据和依赖，然后执行。按包内 `result-template.json` 填写结果；可将它命名为 `result.json` 与相对路径产物打包为 ZIP，或单独导入 JSON。
5. 在“运行结果”导入结果并人工接纳。结果必须引用已有任务 ID 和修订；执行状态不等于科学结论已验证。
6. 在“论文写作”为提纲关联原始条目或已接纳的运行结果，导出 Markdown 报告。

Markdown 阅读与独立定位笔记已实现；PDF 阅读组件已接入，但仍待 Android、macOS、Windows 原生设备验收。笔记不会写回 PDF。提纲导出是保留证据来源的 Markdown 草稿，不包含 Zotero 式文献管理、引用格式化或完整论文排版。

这是一版文件交换 MVP，适合不同网络中的设备人工传递文件。LAN 自动同步、远程自动执行、外部文献检索和论文引用格式化尚未实现。任务 ZIP 只包含规格与结果模板，代码/数据本体需要另外传递和核验。单个文件限制 30 MiB，导入包限制 150 MiB、10,000 个文件；大数据应使用外部存储并在规格中记录可验证的版本与校验值。

## 本地开发

需要 Flutter SDK、Dart SDK 和相应平台的原生工具链。运行 `flutter pub get`，再运行 `flutter run -d android`、`flutter run -d macos` 或 `flutter run -d windows`。检查使用 `flutter analyze` 和 `flutter test`。Windows 需要在 Windows 开发机上构建；macOS 需要完整 Xcode。当前仓库不包含任何私有研究材料。

需要在命令行试验导入时，可运行 `dart run tool/demo_import.dart <研究目录或ZIP> <临时应用数据目录>`。这会将材料复制到指定临时目录并输出对象数量，不会执行研究代码。请不要把真实研究数据目录提交进 Git。

协议、架构和实现范围见 [设计说明](docs/design.md)；实际验证与平台限制见 [验证记录](docs/verification.md)。仓库沿用远端的 MIT [许可](LICENSE)。Flutter 包及其依赖各有许可证，正式发布前需生成并审核完整第三方许可清单，核实 PDF 原生库的再分发要求。
