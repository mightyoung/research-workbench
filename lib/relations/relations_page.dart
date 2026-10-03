import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/research_kinds.dart';
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

  /// research-workflow references as `<prefix>_id` + `<prefix>_rev`.
  static const _flatRefs = [
    ('claims', 'paper', 'papers', '引用论文'),
    ('papers', 'source', 'sources', '来源'),
  ];

  /// research-workflow references as `{id, rev}` maps or lists of them; a
  /// null target means each reference names its own `kind`.
  static const _nestedRefs = <(String, String, String?, String)>[
    ('claims', 'conflicts', 'claims', '冲突主张'),
    ('opportunities', 'supports', 'claims', '支持依据'),
    ('opportunities', 'refutes', 'claims', '反驳依据'),
    ('opportunities', 'search_refs', 'searches', '检索依据'),
    ('opportunities', 'tension_refs', 'tensions', '针对瓶颈'),
    ('tensions', 'evidence', null, '证据'),
    ('experiments', 'opportunity', 'opportunities', '检验候选'),
    ('experiments', 'plan_ref', 'experiments', '执行计划'),
    ('failures', 'evidence', null, '失败证据'),
  ];
  static const _names = {
    ...recordKinds,
    'task': '任务规格',
    'run': '执行结果',
    'outline': '写作提纲',
    'note': '精读证据',
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
    for (final document in widget.store.documents(widget.projectId)) {
      for (final note in widget.store.notes(document.id)) {
        _objects.add(
          _Object(
            note.id,
            'note',
            note.quote.isEmpty ? note.text : note.quote,
            {
              'id': note.id,
              'document': document.relativePath,
              'page_number': note.pageNumber,
              'locator': note.locator,
              'quote': note.quote,
              'entry_id': note.entryId,
              'text': note.text,
            },
          ),
        );
      }
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
      for (final (kind, prefix, target, label) in _flatRefs) {
        if (object.kind == kind && data['${prefix}_id'] != null) {
          _reference(
            object,
            target,
            data['${prefix}_id'],
            data['${prefix}_rev'],
            label,
          );
        }
      }
      for (final (kind, field, target, label) in _nestedRefs) {
        if (object.kind != kind) continue;
        final value = data[field];
        final refs = value is Map
            ? [value]
            : value is List
            ? value.whereType<Map>().toList()
            : const <Map>[];
        for (final ref in refs) {
          _reference(
            object,
            target ?? '${ref['kind']}',
            ref['id'],
            ref['rev'],
            label,
          );
        }
      }
      if (object.kind == 'task' &&
          data['spec'] is Map &&
          data['spec']['source'] is Map) {
        final ref = data['spec']['source'] as Map;
        _reference(object, '${ref['kind']}', ref['id'], ref['rev'], '实施计划');
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
      if (object.kind == 'note' && data['entry_id'] != null) {
        final matches = _objects
            .where((e) => e.key == data['entry_id'])
            .toList();
        _resolved(object, matches, '笔记关联', '${data['entry_id']}');
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

  Widget _graph(_Object selected, ValueChanged<String> onNeighbor) {
    final edges = _links
        .where((edge) => edge.from == selected.key || edge.to == selected.key)
        .take(8)
        .toList();
    final neighbors = <String>{
      for (final edge in edges) edge.from == selected.key ? edge.to : edge.from,
    }.toList();
    final centers = <String, Offset>{selected.key: const Offset(360, 170)};
    for (var i = 0; i < neighbors.length; i++) {
      final angle = -math.pi / 2 + i * 2 * math.pi / neighbors.length;
      centers[neighbors[i]] = Offset(
        360 + 250 * math.cos(angle),
        170 + 115 * math.sin(angle),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('关系图', style: Theme.of(context).textTheme.titleMedium),
        const Text('箭头表示明确引用方向；点击节点查看来源。最多显示当前对象的 8 条关联。'),
        const SizedBox(height: 8),
        SizedBox(
          key: const Key('research-relation-graph'),
          height: 340,
          child: InteractiveViewer(
            constrained: false,
            minScale: .5,
            maxScale: 2.5,
            child: SizedBox(
              width: 720,
              height: 340,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _RelationGraphPainter(
                        centers,
                        edges,
                        Theme.of(context).colorScheme.outline,
                      ),
                    ),
                  ),
                  for (final position in centers.entries)
                    Positioned(
                      left: position.value.dx - 78,
                      top: position.value.dy - 28,
                      width: 156,
                      height: 56,
                      child: Material(
                        color: position.key == selected.key
                            ? Theme.of(context).colorScheme.primaryContainer
                            : Theme.of(
                                context,
                              ).colorScheme.surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(10),
                        child: InkWell(
                          key: Key('relation-node-${position.key}'),
                          borderRadius: BorderRadius.circular(10),
                          onTap: position.key == selected.key
                              ? null
                              : () => onNeighbor(position.key),
                          child: Padding(
                            padding: const EdgeInsets.all(6),
                            child: Center(
                              child: Text(
                                _objects
                                    .firstWhere((o) => o.key == position.key)
                                    .title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
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
          const SizedBox(height: 16),
          _graph(object, onNeighbor),
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

class _RelationGraphPainter extends CustomPainter {
  const _RelationGraphPainter(this.centers, this.edges, this.color);
  final Map<String, Offset> centers;
  final List<_Link> edges;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    for (final edge in edges) {
      final from = centers[edge.from];
      final to = centers[edge.to];
      if (from == null || to == null) continue;
      canvas.drawLine(from, to, stroke);
      final length = (to - from).distance;
      if (length == 0) continue;
      final direction = (to - from) / length;
      final normal = Offset(-direction.dy, direction.dx);
      final tip = from + (to - from) * .68;
      final arrow = Path()
        ..moveTo(tip.dx, tip.dy)
        ..lineTo(
          tip.dx - direction.dx * 12 + normal.dx * 6,
          tip.dy - direction.dy * 12 + normal.dy * 6,
        )
        ..lineTo(
          tip.dx - direction.dx * 12 - normal.dx * 6,
          tip.dy - direction.dy * 12 - normal.dy * 6,
        )
        ..close();
      canvas.drawPath(arrow, fill);
    }
  }

  @override
  bool shouldRepaint(covariant _RelationGraphPainter oldDelegate) =>
      oldDelegate.centers != centers ||
      oldDelegate.edges != edges ||
      oldDelegate.color != color;
}
