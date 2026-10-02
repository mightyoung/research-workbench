# 验证记录（2026-10-02）

## 本地功能修复（尚未推送）

- 临时工作副本执行 `flutter analyze`：0 问题；`flutter test --reporter expanded`：18 项通过。新增跨设备任务 ZIP 导入、用户显式执行记录、带附件结果 ZIP 回传的真实文件测试；新增回环地址上的短期配对、仅共享用户选定文件的 LAN 测试；手机控件测试覆盖任务执行状态编辑与 LAN 入口未监听状态。
- 导出界面改用 `file_picker` 的 `saveFile(bytes: ...)`，以支持 Android 系统文件保存 URI；这一原生对话框尚未在健康 Android 设备验收。
- 先前的 Android APK 与下方原生截图属于旧开发版，**不包含本节功能改动**。本节不声称 Android、macOS 或 Windows 原生验收通过。

## 已验证

- `flutter analyze`：目标仓库无问题，原始输出保存在本机忽略目录 `artifacts/analyze.log`。
- `flutter test --reporter expanded`：目标仓库 13 项通过，原始输出保存在 `artifacts/test.log`。覆盖目录/ZIP 快照与路径拒绝、任务/结果身份绑定、关系引用解析，以及桌面和手机尺寸下的阅读、笔记、任务修订、结果人工接纳、关系入口和提纲操作。测试使用合成资料。
- `flutter build apk --debug --target-platform android-arm64 --no-pub`：在与目标仓库源码一致的 `/tmp/research-workbench-stage` 临时构建副本中成功执行。原始输出保存在本机 `artifacts/android/build.log`，APK 已复制到 `artifacts/android/app-debug.apk`（145,372,079 字节，SHA-256 `36b9bd6abcf89a46e0163f02b041e3a120761ebe3117f0c6a6cc1e233cf8b8a9`）。这些文件被 Git 忽略，未上传远端。最终 APK 在本任务启动的 `Medium_Phone_API_36` 模拟器上 `adb install -r` 成功，安装原始输出保存在 `artifacts/android/install.log`；`am start` 成功，应用成为前台 Activity。真实截图 `artifacts/android/retry-before-action.png` 显示 Android **Digital Wellbeing isn't responding** 系统弹窗遮挡工作台。按后续授权，点选弹窗的 **Close app**，未清除数据；随即 `artifacts/android/retry-after-close.png` 显示 **Process system isn't responding**。此时停止模拟器操作。因此原生 UI、文件选择器、PDF 显示与文件往返仍未验收。APK 仅为开发调试产物，不是发布包。
- `tool/demo_import.dart` 使用本机私有研究目录验证了只读源导入；输入材料、快照与计数输出均留在本机，被 Git 忽略，不包含在发布仓库中。导入的实验计划不能视为已执行实验。

## 平台与功能边界

- 本机只有 Xcode Command Line Tools，`xcodebuild -version` 提示需要完整 Xcode；未完成 macOS 原生构建。Windows 原生构建需要 Windows 开发机。本轮没有提交或发布任何安装包。
- Android 构建/安装成功并不能证明原生文件选择器、PDF 渲染、导出目录写入已在设备端可用。这些仍需目标平台实机验收。
- Markdown 阅读、PDF 阅读组件、定位文字笔记及证据关联到 Markdown 提纲均已在源码实现；widget 测试覆盖 Markdown/笔记和提纲关联，PDF 真机渲染未验收。笔记存放于 SQLite，不写进 PDF；导出的报告是附来源记录的 Markdown 草稿，不是完成排版、引用样式与投稿检查的论文。
- 文件包可通过任何人工文件传输渠道送往异网设备；当前应用不提供 LAN 服务、云同步和远程自动执行。任务包中的代码/数据引用是描述字段，具体文件、版本、环境、许可证和实验可重复性由执行方核验。
- 结果导入先保留为未接纳运行；“接纳为证据”是用户操作，不对科学真实性作自动判断。原始 JSONL 字段及状态保留，缺失或多义的关系不自动推断。
- 导入资料复制到应用私有目录。应用尚无用户级 ACL、加密库或协作权限模型；不要把这版当作多用户服务器。
