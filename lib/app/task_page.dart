import 'dart:convert';

import 'package:flutter/material.dart';

import '../core/exchange.dart';
import '../core/models.dart';
import '../core/store.dart';
import 'page_common.dart';

/// Research tasks: specs, revisions, manual runs and offline task packages.
class TaskPage extends StatefulWidget {
  const TaskPage({
    super.key,
    required this.store,
    required this.projectId,
    required this.onImportResult,
    required this.onImportTask,
    required this.onRunStarted,
    required this.onExport,
  });
  final WorkbenchStore store;
  final String projectId;
  final VoidCallback onImportResult, onImportTask, onRunStarted;
  final ExportFile onExport;

  @override
  State<TaskPage> createState() => _TaskPageState();
}

class _TaskPageState extends State<TaskPage> {
  WorkbenchStore get store => widget.store;

  Future<void> _edit([ResearchTask? existing]) async {
    if (await editTaskDialog(context, store, widget.projectId, existing)) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final tasks = store.tasks(widget.projectId);
    return pageLayout([
      Wrap(
        spacing: 12,
        runSpacing: 8,
        children: [
          FilledButton.icon(
            onPressed: () => _edit(),
            icon: const Icon(Icons.add),
            label: const Text('创建研究 / 实验任务'),
          ),
          OutlinedButton.icon(
            onPressed: widget.onImportResult,
            icon: const Icon(Icons.file_download_outlined),
            label: const Text('导入运行结果'),
          ),
          OutlinedButton.icon(
            onPressed: widget.onImportTask,
            icon: const Icon(Icons.archive_outlined),
            label: const Text('导入任务包'),
          ),
        ],
      ),
      const Text('任务导出为离线包。另一台设备按说明执行，再填写结果包带回。工作台不会执行包内命令。'),
      ...tasks.map(
        (t) => SectionCard(
          '${t.title} · r${t.revision}',
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t.goal),
              if (t.spec['source'] case {'id': final id, 'rev': final rev})
                Text('来源实验计划：$id · r$rev'),
              const SizedBox(height: 8),
              SelectableText(
                '任务 ID：${t.id}',
                style: const TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: () => _edit(t),
                    child: const Text('编辑并保存新修订'),
                  ),
                  OutlinedButton(
                    onPressed: () async {
                      if (await confirmDialog(
                        context,
                        '开始执行记录',
                        '请先核对任务规格、代码、数据和环境。工作台只记录状态；执行命令需要你在可信工具中明确启动。',
                      )) {
                        store.startManualRun(t);
                        widget.onRunStarted();
                      }
                    },
                    child: const Text('开始执行记录'),
                  ),
                  FilledButton.icon(
                    onPressed: () => widget.onExport(
                      (dir) => ResearchExchange(store).exportTask(t, dir),
                      'application/zip',
                    ),
                    icon: const Icon(Icons.upload_file_outlined),
                    label: const Text('导出离线任务包'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      if (tasks.isEmpty) const Text('尚无任务。将候选的问题、实验参数和预期结果写入第一份任务规格。'),
    ]);
  }
}

/// Creates a task or saves a new revision of [existing]; true when saved.
Future<bool> editTaskDialog(
  BuildContext context,
  WorkbenchStore store,
  String projectId, [
  ResearchTask? existing,
]) async {
  final t = TextEditingController(text: existing?.title ?? '');
  final goal = TextEditingController(text: existing?.goal ?? '');
  final spec = TextEditingController(
    text: const JsonEncoder.withIndent('  ').convert(
      existing?.spec ??
          {
            'parameters': <String, dynamic>{},
            'dataReferences': <String>[],
            'codeReference': '',
            'environment': '',
            'expectedResults': <String>['metrics.json', 'run.log'],
            'command': '',
          },
    ),
  );
  String? error;
  final result = await showDialog<Map<String, dynamic>>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, setDialog) => AlertDialog(
        title: Text(existing == null ? '新建任务规格' : '保存任务新修订'),
        content: SizedBox(
          width: 700,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: t,
                  decoration: const InputDecoration(labelText: '任务名称'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: goal,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(labelText: '问题与预期结论范围'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: spec,
                  minLines: 10,
                  maxLines: 18,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  decoration: InputDecoration(
                    labelText: '参数、数据、代码、环境与预期产物（JSON）',
                    errorText: error,
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              try {
                final parsed = jsonDecode(spec.text);
                if (parsed is! Map<String, dynamic>) {
                  throw const FormatException('规格须是 JSON 对象');
                }
                if (t.text.trim().isEmpty || goal.text.trim().isEmpty) {
                  throw const FormatException('名称和目标不能为空');
                }
                Navigator.pop(c, parsed);
              } catch (e) {
                setDialog(() => error = '$e');
              }
            },
            child: const Text('保存规格'),
          ),
        ],
      ),
    ),
  );
  if (result == null) return false;
  store.saveTask(
    id: existing?.id,
    projectId: projectId,
    title: t.text.trim(),
    goal: goal.text.trim(),
    spec: result,
  );
  return true;
}
