import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../core/case_models.dart';
import '../core/case_store.dart';
import '../core/research_skill.dart';
import '../core/store.dart';

/// Three readings of one research case: links, plan history, and attempts.
/// A missing case can be saved from here with zero candidates.
class CaseViews extends StatefulWidget {
  const CaseViews({
    super.key,
    required this.store,
    required this.projectId,
    this.caseId,
  });

  final WorkbenchStore store;
  final String projectId;
  final String? caseId;

  @override
  State<CaseViews> createState() => _CaseViewsState();
}

class _CaseViewsState extends State<CaseViews>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  late final TextEditingController _question;
  late final TextEditingController _process;
  late final TextEditingController _judgement;
  late final TextEditingController _suggestion;
  String? _caseId;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
    _caseId = widget.caseId;
    final existing = _record;
    _question = TextEditingController(text: existing?.question ?? '');
    _process = TextEditingController(text: existing?.processState ?? '');
    _judgement = TextEditingController(
      text: existing?.scientificJudgement ?? '',
    );
    _suggestion = TextEditingController(
      text: _latestSourced()?.payload['text'] as String? ?? '',
    );
  }

  @override
  void dispose() {
    _tabs.dispose();
    _question.dispose();
    _process.dispose();
    _judgement.dispose();
    _suggestion.dispose();
    super.dispose();
  }

  ResearchCase? get _record =>
      _caseId == null ? null : widget.store.caseById(_caseId!);

  CaseTimeline? get _timeline =>
      _record == null ? null : widget.store.caseTimeline(_record!.id);

  List<CaseEvent> _suggestionsOf(CaseTimeline? timeline) => [
    for (final event in timeline?.events ?? const <CaseEvent>[])
      if (event.type == 'ai_suggestion' || event.type == 'ai_suggestion_edit')
        event,
  ];

  CaseEvent? _latestSourced([CaseTimeline? timeline]) {
    for (final event in _suggestionsOf(timeline ?? _timeline).reversed) {
      if (event.sourceRefs.isNotEmpty) return event;
    }
    return null;
  }

  void _saveCase() {
    final existing = _record;
    final id = _caseId ?? const Uuid().v4();
    widget.store.saveCase(
      ResearchCase(
        id: id,
        projectId: widget.projectId,
        question: _question.text,
        methodCommit: existing?.methodCommit ?? defaultMethodCommit,
        workflowId: existing?.workflowId,
        candidates: existing?.candidates ?? const [],
        processState: _process.text,
        scientificJudgement: _judgement.text,
      ),
    );
    setState(() => _caseId = id);
  }

  void _saveSuggestion() {
    final id = _caseId;
    final source = _latestSourced();
    if (id == null || source == null) return;
    widget.store.appendEvent(id, 'ai_suggestion_edit', source.sourceRefs, {
      'text': _suggestion.text,
      'edited': true,
    });
    setState(() {});
  }

  String _header(ResearchCase? item) {
    if (item == null) {
      return '尚未建立研究记录。缺证据。下一步：保存案例，候选可以为空。';
    }
    final stage = item.processState.isEmpty ? '未填写' : item.processState;
    final gap = item.candidates.isEmpty ? '缺证据。' : '';
    final next = item.candidates.isEmpty
        ? '下一步：补一条来源，或继续记下计划和执行。'
        : '下一步：核对引用是否都能打开。';
    return '过程：$stage。$gap$next';
  }

  bool _resolved(SourceRef ref) {
    if (ref.kind.isEmpty || ref.sourceId.isEmpty) return false;
    return widget.store
        .entries(widget.projectId, kind: ref.kind)
        .any(
          (entry) =>
              sourceIdOf(entry) == ref.sourceId && revOf(entry) == ref.rev,
        );
  }

  String _link(SourceRef ref) {
    final label = '${ref.kind}/${ref.sourceId}@${ref.rev}';
    return _resolved(ref) ? label : '$label · 缺引用';
  }

  String _aiLabel(CaseEvent event) =>
      event.sourceRefs.isEmpty ? '未确认草稿' : '可修改建议';

  @override
  Widget build(BuildContext context) {
    final record = _record;
    final timeline = _timeline;
    return Scaffold(
      appBar: AppBar(
        title: const Text('研究记录'),
        bottom: TabBar(
          controller: _tabs,
          isScrollable: true,
          tabs: const [
            Tab(text: '关系地图'),
            Tab(text: '计划演进'),
            Tab(text: '执行记录'),
          ],
        ),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_header(record)),
                const SizedBox(key: Key('method-hint-slot'), height: 0),
                const SizedBox(height: 8),
                TextField(
                  controller: _question,
                  decoration: const InputDecoration(
                    labelText: '研究问题',
                    isDense: true,
                  ),
                ),
                TextField(
                  controller: _process,
                  decoration: const InputDecoration(
                    labelText: '过程',
                    isDense: true,
                    helperText: '阶段文字只作记录，不要求按顺序完成。',
                  ),
                ),
                TextField(
                  controller: _judgement,
                  decoration: const InputDecoration(
                    labelText: '科学判断',
                    isDense: true,
                  ),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton(
                    onPressed: _saveCase,
                    child: const Text('保存案例'),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [
                _scroll(_map(timeline)),
                _scroll(_plans(timeline)),
                _scroll(_attempts(record, timeline)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _scroll(List<Widget> children) =>
      ListView(padding: const EdgeInsets.all(16), children: children);

  List<Widget> _map(CaseTimeline? timeline) {
    if (timeline == null) {
      return const [Text('保存案例后在这里看候选和引用。')];
    }
    final suggestions = _suggestionsOf(timeline);
    final latest = _latestSourced(timeline);
    final lines = <Widget>[
      if (timeline.researchCase.candidates.isEmpty)
        const Text('候选为空。缺证据。')
      else
        for (final ref in timeline.researchCase.candidates) Text(_link(ref)),
    ];
    for (final event in suggestions) {
      if (event.id == latest?.id) continue;
      lines.add(Text('${_aiLabel(event)} · ${event.payload['text'] ?? ''}'));
      for (final ref in event.sourceRefs) {
        lines.add(Text(_link(ref)));
      }
    }
    if (latest != null) {
      lines.add(const Text('可修改建议'));
      for (final ref in latest.sourceRefs) {
        lines.add(Text(_link(ref)));
      }
      lines.add(
        TextField(
          controller: _suggestion,
          decoration: const InputDecoration(labelText: '修改建议', isDense: true),
        ),
      );
      lines.add(
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: _saveSuggestion,
            child: const Text('保存修改'),
          ),
        ),
      );
    }
    return lines;
  }

  List<Widget> _plans(CaseTimeline? timeline) {
    if (timeline == null) return const [Text('还没有计划版本。')];
    const labels = {'reject': '否决', 'fork': '分叉', 'restart': '重启'};
    return [
      for (final plan in timeline.plans)
        Text(
          'v${plan.version} · ${plan.branch} · ${plan.reason}'
          '${plan.parentVersion == null ? '' : ' · 来自 v${plan.parentVersion}'}',
        ),
      for (final event in timeline.events)
        if (labels.containsKey(event.type))
          Text('${labels[event.type]} · ${event.payload['reason'] ?? ''}'),
    ];
  }

  List<Widget> _attempts(ResearchCase? record, CaseTimeline? timeline) {
    if (record == null || timeline == null) {
      return const [Text('还没有执行记录。')];
    }
    return [
      Text('科学判断：${record.scientificJudgement}'),
      for (final attempt in timeline.attempts) ...[
        Text('${attempt.executorId} · ${attempt.processStatus}'),
        if (attempt.processStatus == 'completed') const Text('技术运行结束'),
      ],
    ];
  }
}
