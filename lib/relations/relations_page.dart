import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/store.dart';

/// A local object explorer. Edges require explicit identifiers and revisions;
/// title similarity and code/data paths are never treated as evidence links.
class RelationsPage extends StatefulWidget {
  const RelationsPage({
    super.key,
    required this.store,
    required this.projectId,
  });
  final WorkbenchStore store;
  final String projectId;

  @override
  State<RelationsPage> createState() => _RelationsPageState();
}

class _Object {
  _Object(this.key, this.kind, this.title, this.data);
  final String key, kind, title;
  final Map<String, dynamic> data;
  String get sourceId => (data['id'] ?? key).toString();
  String get revision => (data['rev'] ?? data['revision'] ?? '未提供').toString();
}

class _Link {
  _Link(this.from, this.to, this.label);
  final String from, to, label;
}

class _RelationsPageState extends State<RelationsPage> {
  final _search = TextEditingController();
  final List<_Object> _objects = [];
  final List<_Link> _links = [];
  final Map<String, List<String>> _unresolved = {};
  String _kind = 'all';
  String? _selected;
  static const _names = {
    'papers': '论文',
    'claims': '主张',
    'opportunities': '候选',
    'experiments': '实验计划',
    'task': '任务规格',
    'run': '执行结果',
    'outline': '写作提纲',
    'other': '其他记录',
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    for (final entry in widget.store.entries(widget.projectId)) {
      _objects.add(_Object(entry.id, entry.kind, entry.title, entry.data));
    }
    // Include previous task revisions so old results remain bound to their
    // actual input rather than silently pointing at the newest task.
    final rows = widget.store.db.select(
      'SELECT * FROM tasks WHERE project_id=? ORDER BY id,revision',
      [widget.projectId],
    );
    for (final row in rows) {
      final task = widget.store.taskFromRow(row);
      _objects.add(
        _Object('task:${task.id}:${task.revision}', 'task', task.title, {
          'id': task.id,
          'revision': task.revision,
          'goal': task.goal,
          'spec': task.spec,
        }),
      );
    }
    for (final run in widget.store.runs(widget.projectId)) {
      _objects.add(
        _Object('run:${run.id}', 'run', run.id, {
          ...run.data,
          'id': run.id,
          'task_id': run.taskId,
          'task_revision': run.taskRevision,
          'status': run.status,
          'accepted': run.accepted,
        }),
      );
    }
    for (final outline in widget.store.outline(widget.projectId)) {
      _objects.add(
        _Object(
          'outline:${outline['id']}',
          'outline',
          outline['heading'].toString(),
          outline,
        ),
      );
    }
    for (final object in _objects) {
      final data = object.data;
      if (object.kind == 'claims' && data['paper_id'] != null) {
        _reference(
          object,
          'papers',
          data['paper_id'],
          data['paper_rev'],
          '引用论文',
        );
      }
      if (object.kind == 'opportunities') {
        for (final field in ['supports', 'refutes']) {
          final refs = data[field];
          if (refs is List) {
            for (final ref in refs.whereType<Map>()) {
              _reference(
                object,
                'claims',
                ref['id'],
                ref['rev'],
                field == 'supports' ? '支持依据' : '反驳依据',
              );
            }
          }
        }
      }
      if (object.kind == 'experiments' && data['opportunity'] is Map) {
        final ref = data['opportunity'] as Map;
        _reference(object, 'opportunities', ref['id'], ref['rev'], '检验候选');
      }
      if (object.kind == 'run') {
        _reference(
          object,
          'task',
          data['task_id'],
          data['task_revision'],
          '执行规格',
        );
      }
      if (object.kind == 'outline') {
        final matches = _objects
            .where((e) => e.key == data['evidence_id'])
            .toList();
        _resolved(object, matches, '写作引用', data['evidence_id'].toString());
      }
    }
    if (_objects.isNotEmpty) _selected = _objects.first.key;
  }

  void _reference(
    _Object from,
    String kind,
    dynamic id,
    dynamic rev,
    String label,
  ) {
    // Missing revisions stay unresolved instead of guessing the latest source.
    final matches = rev == null || id == null
        ? <_Object>[]
        : _objects
              .where(
                (o) =>
                    o.kind == kind &&
                    o.sourceId == id.toString() &&
                    o.revision == rev.toString(),
              )
              .toList();
    _resolved(from, matches, label, '$id · 修订 ${rev ?? '未提供'}');
  }

  void _resolved(
    _Object from,
    List<_Object> matches,
    String label,
    String reference,
  ) {
    if (matches.length == 1) {
      _links.add(_Link(from.key, matches.single.key, label));
    } else {
      _unresolved
          .putIfAbsent(from.key, () => [])
          .add(
            '$label：$reference（${matches.isEmpty ? '目标未导入或缺少修订' : '存在多个同身份记录'}）',
          );
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _select(String key, {bool openDetail = false}) {
    setState(() => _selected = key);
    if (openDetail) {
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => SizedBox(
          height: MediaQuery.sizeOf(context).height * .85,
          child: StatefulBuilder(
            builder: (context, update) => _detail(
              _objects.firstWhere((o) => o.key == _selected),
              onNeighbor: (key) {
                setState(() => _selected = key);
                update(() {});
              },
            ),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final query = _search.text.trim().toLowerCase();
    final visible = _objects
        .where(
          (o) =>
              (_kind == 'all' || o.kind == _kind) &&
              '${o.title} ${o.sourceId}'.toLowerCase().contains(query),
        )
        .toList();
    final kinds = _objects.map((o) => o.kind).toSet().toList()..sort();
    return Material(
      color: Colors.transparent,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${_objects.length} 个对象 · ${_links.length} 条明确关联',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const Text('选择对象追溯来源与一跳关系；未解析引用保留原始标识，不推断证据。'),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _search,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      labelText: '搜索标题或来源 ID',
                      prefixIcon: Icon(Icons.search),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                DropdownButton<String>(
                  value: _kind,
                  onChanged: (v) => setState(() => _kind = v!),
                  items: ['all', ...kinds]
                      .map(
                        (k) => DropdownMenuItem(
                          value: k,
                          child: Text(k == 'all' ? '全部类型' : _names[k] ?? k),
                        ),
                      )
                      .toList(),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Expanded(
              child: LayoutBuilder(
                builder: (context, size) {
                  final wide = size.maxWidth >= 850;
                  final list = visible.isEmpty
                      ? const Center(child: Text('没有匹配对象'))
                      : ListView.builder(
                          itemCount: visible.length,
                          itemBuilder: (context, index) {
                            final o = visible[index];
                            return Card(
                              child: ListTile(
                                selected: _selected == o.key,
                                title: Text(
                                  o.title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(
                                  '${_names[o.kind] ?? o.kind} · ${o.sourceId} · 修订 ${o.revision}',
                                ),
                                trailing: const Icon(Icons.chevron_right),
                                onTap: () => _select(o.key, openDetail: !wide),
                              ),
                            );
                          },
                        );
                  if (!wide) return list;
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(flex: 2, child: list),
                      const VerticalDivider(width: 24),
                      Expanded(
                        flex: 3,
                        child: _selected == null
                            ? const Center(child: Text('选择研究对象'))
                            : _detail(
                                _objects.firstWhere((o) => o.key == _selected),
                                onNeighbor: (key) => _select(key),
                              ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _detail(_Object object, {required ValueChanged<String> onNeighbor}) {
    final edges = _links
        .where((e) => e.from == object.key || e.to == object.key)
        .toList();
    final unresolved = _unresolved[object.key] ?? [];
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _names[object.kind] ?? object.kind,
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const SizedBox(height: 8),
          SelectableText(
            object.title,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          SelectableText(
            '来源 ID：${object.sourceId}\n修订：${object.revision}\n本地对象 ID：${object.key}',
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            icon: const Icon(Icons.copy),
            label: const Text('复制对象记录'),
            onPressed: () async {
              await Clipboard.setData(
                ClipboardData(
                  text: const JsonEncoder.withIndent('  ').convert(object.data),
                ),
              );
              if (mounted) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('已复制原始记录')));
              }
            },
          ),
          const Divider(height: 32),
          Text('一跳关系', style: Theme.of(context).textTheme.titleMedium),
          if (edges.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('当前没有已解析的明确关联。代码与数据路径可在原始记录中查看。'),
            ),
          for (final edge in edges)
            Builder(
              builder: (context) {
                final outbound = edge.from == object.key;
                final neighbor = _objects.firstWhere(
                  (o) => o.key == (outbound ? edge.to : edge.from),
                );
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    outbound ? Icons.arrow_outward : Icons.south_west,
                  ),
                  title: Text(
                    neighbor.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${outbound ? '出向' : '入向'} · ${edge.label} · ${_names[neighbor.kind] ?? neighbor.kind} · 修订 ${neighbor.revision}',
                  ),
                  onTap: () => onNeighbor(neighbor.key),
                );
              },
            ),
          if (unresolved.isNotEmpty) ...[
            const Divider(height: 32),
            Text(
              '未解析引用（${unresolved.length}）',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            for (final reference in unresolved)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: SelectableText(reference),
              ),
          ],
          const Divider(height: 32),
          Text('来源记录与定位', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          SelectableText(
            const JsonEncoder.withIndent('  ').convert(object.data),
          ),
        ],
      ),
    );
  }
}
