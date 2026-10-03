import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../core/exchange.dart';
import '../core/store.dart';
import 'lan_transfer_page.dart';
import 'page_common.dart';
import 'workbench_app.dart';

/// Import, export and LAN transfer flows of the workbench home. They pick
/// files, confirm with the user, and move the home to the affected section.
mixin TransferFlows on State<WorkbenchHome> {
  int get section;
  set section(int value);
  String? get projectId;
  set projectId(String? value);

  bool busy = false;
  String? lastExportPath;
  WorkbenchStore get store => widget.store;

  void refresh() => setState(() {});
  void message(String value) => showMessage(context, value);

  Future<void> action(Future<void> Function() fn) async {
    setState(() => busy = true);
    try {
      await fn();
      if (mounted) refresh();
    } catch (e) {
      message('操作未完成：$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<bool> confirm(String title, String description) =>
      confirmDialog(context, title, description);
  Future<String?> pickFile(List<String> extensions) async {
    if (widget.pickImportFile != null) {
      return widget.pickImportFile!(extensions);
    }
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: extensions,
    );
    return files.isEmpty ? null : files.first.path;
  }

  Future<void> importResearch(bool folder) async {
    final path = folder
        ? await FilePicker.getDirectoryPath(
            dialogTitle: '选择 research-workflow 研究目录',
          )
        : await pickFile(['zip']);
    if (path == null || !mounted) return;
    if (!await confirm(
      '导入研究快照',
      '将所选材料复制到工作台私有资料库，原目录保持不变。\n$path\n论文、主张和候选保留原有状态。',
    )) {
      return;
    }
    final target = await chooseImportTarget(path);
    if (target == null) return;
    await action(() async {
      final p = await ResearchExchange(
        store,
      ).importResearch(path, intoProjectId: target.isEmpty ? null : target);
      projectId = p.id;
      section = 0;
      message(target.isEmpty ? '已导入 ${p.title}' : '已更新 ${p.title}，笔记与提纲保留');
    });
  }

  /// Returns a project ID to refresh, '' for a new project, or null to cancel.
  Future<String?> chooseImportTarget(String path) async {
    final name = p
        .basename(path)
        .replaceFirst(RegExp(r'\.zip$', caseSensitive: false), '');
    final projects = store.projects()
      ..sort((a, b) => (b.title == name ? 1 : 0) - (a.title == name ? 1 : 0));
    if (projects.isEmpty) return '';
    return showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('导入到哪个项目？'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, ''),
            child: Text('新建项目「$name」'),
          ),
          for (final project in projects)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, project.id),
              child: Text(
                '更新「${project.title}」${project.title == name ? ' · 同名' : ''}'
                '\n保留笔记、任务、运行与提纲',
              ),
            ),
        ],
      ),
    );
  }

  String get exportDirectory => p.join(store.rootPath, 'exports');

  Future<void> saveGenerated(String path, String mimeType) async {
    lastExportPath = path;
    final bytes = Uint8List.fromList(await File(path).readAsBytes());
    final name = p.basename(path);
    final uri =
        await (widget.saveExportFile?.call(name, bytes, mimeType) ??
            FilePicker.saveFile(
              fileName: name,
              bytes: bytes,
              mimeType: mimeType,
            ));
    if (uri != null) {
      message('已保存到 ${uri.toString()}');
    } else {
      message('已取消保存；生成的文件仍在本机资料库。');
    }
  }

  Future<void> importTask() async {
    final path = await pickFile(['zip']);
    if (path == null || !mounted) return;
    if (!await confirm('导入任务包', '读取任务规格并保留原包，不会执行其中的命令。\n$path')) {
      return;
    }
    await action(() async {
      final task = await ResearchExchange(store).importTask(path);
      projectId = task.projectId;
      section = 2;
      message('已导入任务 ${task.title} · r${task.revision}');
    });
  }

  Future<void> importResult() async {
    final path = await pickFile(['json', 'zip']);
    if (path == null || !mounted) return;
    if (!await confirm('导入运行结果', '导入后先进入待接纳列表；命令仅作记录，不会执行。\n$path')) return;
    await action(() async {
      final run = await ResearchExchange(store).importResult(path);
      section = 3;
      message('已导入运行 ${run.id}，等待关联为证据');
    });
  }

  Future<bool> importLanFile(String path, String kind) async {
    final exchange = ResearchExchange(store);
    if (kind == 'task') {
      final task = await exchange.importTask(path);
      if (mounted) {
        setState(() {
          projectId = task.projectId;
          section = 2;
        });
      }
    } else if (kind == 'result') {
      final run = await exchange.importResult(path);
      final task = store.taskRevision(run.taskId, run.taskRevision)!;
      if (mounted) {
        setState(() {
          projectId = task.projectId;
          section = 3;
        });
      }
    } else if (kind == 'research') {
      final target = await chooseImportTarget(path);
      if (target == null) return false;
      final project = await exchange.importResearch(
        path,
        intoProjectId: target.isEmpty ? null : target,
      );
      if (mounted) {
        setState(() {
          projectId = project.id;
          section = 0;
        });
      }
    } else {
      throw const FormatException('Unknown received content type');
    }
    message('局域网文件已导入本机资料库。');
    return true;
  }

  Future<void> openLan() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => LanTransferPage(
          rootPath: store.rootPath,
          suggestedFile: lastExportPath,
          onImport: importLanFile,
        ),
      ),
    );
    if (mounted) refresh();
  }
}
