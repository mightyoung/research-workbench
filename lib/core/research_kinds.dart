import 'dart:convert';

/// Record kinds written by research-workflow (`research/<kind>.jsonl`), in
/// reading order. Anything else imports as `other`.
const recordKinds = {
  'sources': '来源',
  'papers': '论文',
  'claims': '主张',
  'opportunities': '候选',
  'searches': '检索记录',
  'tensions': '矛盾与瓶颈',
  'experiments': '实验计划',
  'failures': '失败记录',
  'handoffs': '交接',
};

/// Fields that carry the research judgment of a record, shown above the raw
/// JSON. Dotted keys read nested maps.
const judgmentFields = <String, Map<String, String>>{
  'claims': {
    'evidence_kind': '证据性质',
    'supports_statement': '支持的表述',
    'does_not_support': '不支持的结论',
    'scope': '适用范围',
    'locator_reliability': '定位可靠性',
    'material_access': '原文可得性',
  },
  'opportunities': {
    'decision': '决定',
    'novelty': '新颖性',
    'change_decision_if': '何时改变决定',
    'importance': '重要性',
    'critical_unknown': '关键未知',
    'closest_work': '最强近邻',
    'minimal_experiment': '最小实验',
    'stop_conditions': '停止条件',
  },
  'searches': {
    'query': '检索式',
    'layer': '层次',
    'status': '状态',
    'coverage_claim': '覆盖声明',
  },
  'tensions': {
    'tension_type': '类型',
    'observation': '现象',
    'alternative_explanations': '其他解释',
    'importance': '重要性',
  },
  'experiments': {
    'phase': '阶段',
    'actual.result': '实验结论',
    'actual.discriminating': '能否区分解释',
    'actual.execution_state': '执行状态',
    'actual.reason': '理由',
  },
  'failures': {
    'failure_type': '失败类型',
    'cause': '原因',
    'generalization_scope': '推广范围',
  },
  'handoffs': {'step': '步骤', 'step_state': '状态', 'pending_questions': '待解决问题'},
};

/// Short facts for list subtitles, across kinds.
const summaryFields = [
  'evidence_kind',
  'decision',
  'novelty',
  'tension_type',
  'failure_type',
  'step_state',
  'layer',
  'phase',
  'actual.result',
];

const _valueLabels = {
  'paper_statement': '论文结论',
  'inference': '推断',
  'hypothesis': '假设',
  'continue': '继续',
  'revise': '调整',
  'park': '搁置',
  'abandon': '放弃',
  'supporting': '支持',
  'refuting': '反驳',
  'inconclusive': '无定论',
  'planned': '计划',
  'executed': '已执行',
};

dynamic fieldValue(Map<String, dynamic> data, String path) {
  dynamic value = data;
  for (final part in path.split('.')) {
    if (value is! Map) return null;
    value = value[part];
  }
  return value;
}

String displayValue(dynamic value) => switch (value) {
  null => '',
  bool b => b ? '是' : '否',
  String s => _valueLabels[s] ?? s,
  List l => l.map(displayValue).join('；'),
  Map m => jsonEncode(m),
  _ => '$value',
};
