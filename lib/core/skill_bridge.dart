import 'models.dart';

/// Conversions between workbench tasks/runs and research-workflow
/// `experiments` records. Rules mirror the skill's validator so an exported
/// record is not weaker than one the skill would write itself.

const runResults = {'supporting', 'refuting', 'inconclusive'};
const _planFields = [
  'opportunity',
  'observation',
  'explanation',
  'strongest_rival',
  'metric',
  'unit',
  'predictions',
  'uncertainty',
  'discrimination_limit',
  'baseline_sufficiency',
  'budget',
];

/// Task draft for a planned experiment, pinned to its source `id` + `rev`.
({String title, String goal, Map<String, dynamic> spec}) taskFromExperiment(
  ResearchEntry plan,
) {
  final d = plan.data;
  if (plan.kind != 'experiments' || d['id'] == null || d['rev'] is! int) {
    throw const FormatException('只能从带 id 与修订号的实验计划生成任务');
  }
  if (d['phase'] == 'executed') {
    throw const FormatException('已执行的实验记录不能再生成任务');
  }
  final goal = [
    if (d['explanation'] != null) '检验解释：${d['explanation']}',
    if (d['strongest_rival'] != null) '最强对手解释：${d['strongest_rival']}',
    if (d['observation'] != null) '观察：${d['observation']}',
  ].join('\n');
  return (
    title: plan.title,
    goal: goal.isEmpty ? plan.title : goal,
    spec: {
      'source': {'kind': 'experiments', 'id': d['id'], 'rev': d['rev']},
      for (final key in _planFields)
        if (d.containsKey(key)) key: d[key],
      'parameters': <String, dynamic>{},
      'dataReferences': <String>[],
      'codeReference': '',
      'environment': '',
      'expectedResults': <String>['metrics.json', 'run.log'],
      'command': '',
    },
  );
}

/// The user's research judgment of a finished run, kept apart from the
/// execution status and from evidence acceptance.
Map<String, dynamic> runAssessment({
  required String status,
  required String result,
  required bool discriminating,
  required String reason,
  num? budgetSpent,
  required DateTime at,
}) {
  if (!runResults.contains(result)) {
    throw FormatException('未知结论：$result');
  }
  if (status != 'completed' && status != 'failed') {
    throw const FormatException('运行结束（已完成或失败）后才能评估结论');
  }
  if (status == 'failed' && result != 'inconclusive') {
    throw const FormatException('执行失败只能记为无定论，不能支持或反驳假设');
  }
  if (!discriminating && result != 'inconclusive') {
    throw const FormatException('不能区分竞争解释的结果只能记为无定论');
  }
  if (reason.trim().isEmpty) throw const FormatException('请写明判断理由');
  if (budgetSpent != null && (!budgetSpent.isFinite || budgetSpent < 0)) {
    throw const FormatException('花费须为非负数');
  }
  return {
    'result': result,
    'discriminating': discriminating,
    'reason': reason.trim(),
    'budget_spent': ?budgetSpent,
    'assessed_at': at.toUtc().toIso8601String(),
  };
}

/// research-workflow `experiments` record (`phase: executed`) for a run of a
/// task generated from a planned experiment.
Map<String, dynamic> executedExperiment({
  required ResearchTask task,
  required ResearchRun run,
  required DateTime now,
}) {
  final source = task.spec['source'];
  if (source is! Map ||
      source['kind'] != 'experiments' ||
      source['id'] == null ||
      source['rev'] is! int) {
    throw const FormatException('任务不是从实验计划生成的，无法写回 plan_ref');
  }
  final assessment = run.data['workbench_assessment'];
  if (assessment is! Map) throw const FormatException('请先评估这次运行的研究结论');
  if (assessment['budget_spent'] is! num) {
    throw const FormatException('评估中缺少实际花费，research-workflow 需要它核对预算');
  }
  final executedAt = run.data['finishedAt'] ?? run.data['executed_at'];
  if (executedAt is! String || executedAt.isEmpty) {
    throw const FormatException('结果缺少执行完成时间（finishedAt）');
  }
  final metrics = run.data['metrics'];
  final measured = [
    if (metrics is Map)
      for (final v in metrics.values)
        if (v is num && v.isFinite) v,
  ];
  if (measured.isEmpty) throw const FormatException('没有可写回的数值指标');
  final short = run.id.length > 8 ? run.id.substring(0, 8) : run.id;
  return {
    'schema_version': 2,
    'id': '${source['id']}-run-$short',
    'rev': 1,
    'updated_at': now.toUtc().toIso8601String(),
    'title': '${task.title} · 运行 $short',
    'phase': 'executed',
    'plan_ref': {'id': source['id'], 'rev': source['rev']},
    if (task.spec['opportunity'] is Map)
      'opportunity': task.spec['opportunity'],
    'actual': {
      'executed_at': executedAt,
      'measured_values': measured,
      'result': assessment['result'],
      'discriminating': assessment['discriminating'],
      'reason': assessment['reason'],
      'budget_spent': assessment['budget_spent'],
      'execution_state': switch (run.status) {
        'completed' => 'completed',
        'failed' => 'technical_failure',
        _ => throw const FormatException('运行尚未结束'),
      },
    },
    'workbench': {
      'run_id': run.id,
      'task_id': task.id,
      'task_revision': task.revision,
      'metrics': metrics,
      'accepted': run.accepted,
    },
  };
}
