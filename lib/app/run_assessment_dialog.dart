import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/research_kinds.dart';

typedef RunAssessmentInput = ({
  String result,
  bool discriminating,
  String reason,
  num? budgetSpent,
});

/// One-line summary of a run's research assessment, or null when unassessed.
String? assessmentSummary(ResearchRun run) {
  final a = run.data['workbench_assessment'];
  if (a is! Map) return null;
  return [
    '研究结论：${displayValue(a['result'])}',
    a['discriminating'] == true ? '能区分竞争解释' : '不能区分竞争解释',
    if (a['budget_spent'] != null) '花费 ${a['budget_spent']}',
    '${a['reason']}',
  ].join(' · ');
}

/// Asks what a finished run means for its hypothesis. Validation happens in
/// the store; this only collects input.
Future<RunAssessmentInput?> showRunAssessmentDialog(
  BuildContext context,
  ResearchRun run,
) {
  final old = run.data['workbench_assessment'];
  final prior = old is Map ? old : const {};
  var result = '${prior['result'] ?? 'inconclusive'}';
  var discriminating = prior['discriminating'] == true;
  final reason = TextEditingController(text: '${prior['reason'] ?? ''}');
  final budget = TextEditingController(
    text: prior['budget_spent'] == null ? '' : '${prior['budget_spent']}',
  );
  return showDialog<RunAssessmentInput>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, update) => AlertDialog(
        title: const Text('评估研究结论'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('执行状态：${run.status}。这里记录结果对假设意味着什么，与执行是否成功、是否接纳为证据分开保存。'),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: result,
                  decoration: const InputDecoration(labelText: '对假设的结论'),
                  items: const [
                    DropdownMenuItem(value: 'supporting', child: Text('支持')),
                    DropdownMenuItem(value: 'refuting', child: Text('反驳')),
                    DropdownMenuItem(value: 'inconclusive', child: Text('无定论')),
                  ],
                  onChanged: (v) => update(() => result = v!),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: discriminating,
                  onChanged: (v) => update(() => discriminating = v!),
                  title: const Text('结果能区分自身解释与最强对手解释'),
                  subtitle: const Text('不能区分时只能记为无定论'),
                ),
                TextField(
                  controller: reason,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(labelText: '判断理由'),
                ),
                TextField(
                  controller: budget,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: '实际花费（按计划预算单位，写回 skill 时必填）',
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
            onPressed: () => Navigator.pop(c, (
              result: result,
              discriminating: discriminating,
              reason: reason.text,
              budgetSpent: num.tryParse(budget.text.trim()),
            )),
            child: const Text('保存评估'),
          ),
        ],
      ),
    ),
  );
}
