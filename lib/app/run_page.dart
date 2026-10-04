import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../core/exchange.dart';
import '../core/models.dart';
import '../core/research_kinds.dart';
import '../core/store.dart';
import 'page_common.dart';
import 'run_assessment_dialog.dart';

/// Run results: acceptance as evidence, manual run records, comparisons.
class RunPage extends StatefulWidget {
  const RunPage({
    super.key,
    required this.store,
    required this.projectId,
    required this.onImportResult,
    required this.onLinkEvidence,
    required this.onExport,
  });
  final WorkbenchStore store;
  final String projectId;
  final VoidCallback onImportResult;
  final void Function(String id) onLinkEvidence;
  final ExportFile onExport;

  @override
  State<RunPage> createState() => _RunPageState();
}

class _RunPageState extends State<RunPage> {
  WorkbenchStore get store => widget.store;

  @override
  Widget build(BuildContext context) {
    final runs = store.runs(widget.projectId);
    final grouped = <(String, int), List<ResearchRun>>{};
    for (final run in runs) {
      grouped.putIfAbsent((run.taskId, run.taskRevision), () => []).add(run);
    }
    return pageLayout([
      Align(
        alignment: Alignment.centerLeft,
        child: FilledButton.icon(
          onPressed: widget.onImportResult,
          icon: const Icon(Icons.download_outlined),
          label: const Text('导入 JSON / ZIP 结果包'),
        ),
      ),
      const Text('运行结果先保留原始记录。确认关联为证据表示纳入本项目分析，不代表科学结论已经验证。'),
      for (final group in grouped.values.where((items) => items.length >= 2))
        comparisonCard(group),
      ...runs.map(
        (run) => SectionCard(
          '运行 ${run.id}',
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${run.status} · 任务 r${run.taskRevision} · ${run.accepted ? '已关联证据' : '待接纳'}',
              ),
              SelectableText('Task ID：${run.taskId}'),
              if (assessmentSummary(run) case final summary?)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: SelectableText(summary),
                ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 8,
                children: [
                  if (run.data['_localManual'] == true) ...[
                    OutlinedButton(
                      onPressed: () => editRun(run),
                      child: const Text('更新执行记录'),
                    ),
                    FilledButton(
                      onPressed: () => exportRun(run),
                      child: const Text('导出结果包'),
                    ),
                    OutlinedButton(
                      onPressed: () => exportRun(run, chooseArtifacts: true),
                      child: const Text('附加产物并导出'),
                    ),
                  ],
                  if (!run.accepted && run.data['_localManual'] != true)
                    FilledButton(
                      onPressed: () async {
                        if (await confirmDialog(
                          context,
                          '关联为研究证据',
                          '保留此运行的状态、指标、日志和产物引用，并纳入报告。请先核对它的任务修订和数据来源。',
                        )) {
                          store.acceptRun(run.id);
                          setState(() {});
                        }
                      },
                      child: const Text('确认关联为证据'),
                    ),
                  if (run.accepted)
                    OutlinedButton(
                      onPressed: () => widget.onLinkEvidence(run.id),
                      child: const Text('关联论文提纲'),
                    ),
                  if (run.status == 'completed' || run.status == 'failed')
                    OutlinedButton(
                      onPressed: () => assessRun(run),
                      child: const Text('评估研究结论'),
                    ),
                  if (run.data['workbench_assessment'] != null &&
                      store
                              .taskRevision(run.taskId, run.taskRevision)
                              ?.spec['source'] !=
                          null)
                    FilledButton.tonal(
                      onPressed: () => widget.onExport(
                        (dir) => ResearchExchange(
                          store,
                        ).exportSkillExperiment(run, dir),
                        'application/x-ndjson',
                      ),
                      child: const Text('导出给 research-workflow'),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              ExpansionTile(
                title: const Text('原始运行记录'),
                children: [
                  SelectableText(
                    const JsonEncoder.withIndent('  ').convert(run.data),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      if (runs.isEmpty) const Text('尚无返回结果。离线任务包内提供结果格式说明。'),
    ]);
  }

  Widget comparisonCard(List<ResearchRun> comparable) {
    final task = store.taskRevision(
      comparable.first.taskId,
      comparable.first.taskRevision,
    )!;
    final metricKeys = <String>{
      for (final run in comparable)
        for (final key in (run.data['metrics'] as Map? ?? {}).keys)
          key.toString(),
    }.toList()..sort();
    String metric(ResearchRun run, String key) {
      final metrics = run.data['metrics'];
      if (metrics is! Map || !metrics.containsKey(key)) return '—';
      final value = metrics[key];
      return value is Map || value is List ? jsonEncode(value) : '$value';
    }

    DataRow row(String label, String Function(ResearchRun) value) => DataRow(
      cells: [
        DataCell(Text(label)),
        for (final run in comparable)
          DataCell(
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220),
              child: Text(
                value(run),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
      ],
    );

    return SectionCard(
      '同任务结果比较 · ${task.title} · r${task.revision}',
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('不自动判断优劣或科学有效性'),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columns: [
                const DataColumn(label: Text('字段')),
                for (final run in comparable)
                  DataColumn(label: Text('运行 ${run.id.substring(0, 8)}')),
              ],
              rows: [
                row('执行状态', (run) => run.status),
                row('证据接纳', (run) => run.accepted ? '已接纳' : '待接纳'),
                for (final key in metricKeys)
                  row('指标 · $key', (run) => metric(run, key)),
                row('结论', (run) => '${run.data['conclusion'] ?? '—'}'),
                row('研究结论', (run) {
                  final result = fieldValue(
                    run.data,
                    'workbench_assessment.result',
                  );
                  return result == null ? '未评估' : displayValue(result);
                }),
                row(
                  '产物数',
                  (run) => '${(run.data['artifacts'] as List?)?.length ?? 0}',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> assessRun(ResearchRun run) async {
    final input = await showRunAssessmentDialog(context, run);
    if (input == null) return;
    try {
      store.assessRun(
        run.id,
        result: input.result,
        discriminating: input.discriminating,
        reason: input.reason,
        budgetSpent: input.budgetSpent,
      );
      if (mounted) setState(() {});
    } on FormatException catch (e) {
      if (mounted) showMessage(context, '评估未保存：${e.message}');
    }
  }

  Future<void> exportRun(
    ResearchRun run, {
    bool chooseArtifacts = false,
  }) async {
    var paths = <String>[];
    if (chooseArtifacts) {
      final files = await FilePicker.pickFiles(type: FileType.any);
      paths = [
        for (final file in files)
          if (file.path != null) file.path!,
      ];
      if (paths.isEmpty) return;
    }
    await widget.onExport(
      (dir) =>
          ResearchExchange(store).exportResult(run, dir, artifactPaths: paths),
      'application/zip',
    );
  }

  Future<void> editRun(ResearchRun run) async {
    var status = run.status;
    final metrics = TextEditingController(
      text: const JsonEncoder.withIndent(
        '  ',
      ).convert(run.data['metrics'] ?? {}),
    );
    final log = TextEditingController();
    final conclusion = TextEditingController(
      text: '${run.data['conclusion'] ?? ''}',
    );
    String? error;
    final saved = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, update) => AlertDialog(
          title: const Text('更新执行记录'),
          content: SizedBox(
            width: 600,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: status,
                    decoration: const InputDecoration(labelText: '执行状态'),
                    items: const [
                      DropdownMenuItem(value: 'running', child: Text('进行中')),
                      DropdownMenuItem(value: 'completed', child: Text('已完成')),
                      DropdownMenuItem(value: 'failed', child: Text('失败')),
                      DropdownMenuItem(value: 'blocked', child: Text('受阻')),
                    ],
                    onChanged: (value) => status = value ?? status,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: metrics,
                    minLines: 3,
                    maxLines: 7,
                    decoration: InputDecoration(
                      labelText: '指标（JSON）',
                      errorText: error,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: log,
                    minLines: 2,
                    maxLines: 4,
                    decoration: const InputDecoration(labelText: '执行日志'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: conclusion,
                    minLines: 2,
                    maxLines: 4,
                    decoration: const InputDecoration(labelText: '结论 / 待复审'),
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
                  final parsed = jsonDecode(metrics.text);
                  if (parsed is! Map<String, dynamic>) {
                    throw const FormatException('指标须为 JSON 对象');
                  }
                  Navigator.pop(c, parsed);
                } catch (e) {
                  update(() => error = '$e');
                }
              },
              child: const Text('保存执行记录'),
            ),
          ],
        ),
      ),
    );
    if (saved != null) {
      store.updateManualRun(
        run.id,
        status: status,
        metrics: saved,
        log: log.text,
        conclusion: conclusion.text,
      );
      if (mounted) setState(() {});
    }
  }
}
