import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/models.dart';
import '../core/research_kinds.dart';
import '../core/store.dart';

/// Evidence-backed outline: ordered, nested sections, each with an argument,
/// a support level and any number of cited records, runs or reading notes.
class WritingPage extends StatefulWidget {
  const WritingPage({
    super.key,
    required this.store,
    required this.projectId,
    required this.onExportReport,
    required this.onPickEvidence,
    required this.onShowEntry,
    required this.onOpenDocument,
  });
  final WorkbenchStore store;
  final String projectId;
  final VoidCallback onExportReport, onPickEvidence;
  final void Function(ResearchEntry) onShowEntry;
  final void Function(ResearchDocument) onOpenDocument;

  @override
  State<WritingPage> createState() => _WritingPageState();
}

class _WritingPageState extends State<WritingPage> {
  WorkbenchStore get store => widget.store;

  void _guard(void Function() change) {
    try {
      setState(change);
    } on FormatException catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('未保存：${e.message}')));
    }
  }

  Future<void> _edit([OutlineSection? section]) async {
    final heading = TextEditingController(text: section?.heading ?? '');
    final argument = TextEditingController(text: section?.argument ?? '');
    var level = section?.level ?? 1;
    var support = section?.support ?? 'unassessed';
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, update) => AlertDialog(
          title: Text(section == null ? '新增段落' : '编辑段落'),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: heading,
                    decoration: const InputDecoration(labelText: '段落标题'),
                  ),
                  DropdownButtonFormField<int>(
                    initialValue: level,
                    decoration: const InputDecoration(labelText: '层级'),
                    items: const [
                      DropdownMenuItem(value: 1, child: Text('一级')),
                      DropdownMenuItem(value: 2, child: Text('二级')),
                      DropdownMenuItem(value: 3, child: Text('三级')),
                    ],
                    onChanged: (v) => update(() => level = v!),
                  ),
                  if (section != null) ...[
                    TextField(
                      controller: argument,
                      minLines: 2,
                      maxLines: 6,
                      decoration: const InputDecoration(
                        labelText: '本段论述（证据支持什么）',
                      ),
                    ),
                    DropdownButtonFormField<String>(
                      initialValue: support,
                      decoration: const InputDecoration(labelText: '证据支持程度'),
                      items: [
                        for (final MapEntry(:key, :value)
                            in sectionSupport.entries)
                          DropdownMenuItem(value: key, child: Text(value)),
                      ],
                      onChanged: (v) => update(() => support = v!),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('保存段落'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    _guard(() {
      if (section == null) {
        store.addSection(widget.projectId, heading.text, level: level);
      } else {
        store.updateSection(
          section.id,
          heading: heading.text,
          level: level,
          argument: argument.text,
          support: support,
        );
      }
    });
  }

  Future<void> _delete(OutlineSection section) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('删除段落'),
        content: Text('删除「${section.heading}」及其证据关联；证据本身保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) _guard(() => store.deleteSection(section.id));
  }

  @override
  Widget build(BuildContext context) {
    final entries = {for (final e in store.entries(widget.projectId)) e.id: e};
    final notes = <String, (ResearchDocument, ReadingNote)>{
      for (final doc in store.documents(widget.projectId))
        for (final note in store.notes(doc.id)) note.id: (doc, note),
    };
    final links = store.outline(widget.projectId);
    final sections = store.sections(widget.projectId);
    final theme = Theme.of(context);

    Widget evidenceTile(Map<String, dynamic> link) {
      final id = '${link['evidence_id']}';
      final entry = entries[id];
      final note = notes[id];
      final title =
          entry?.title ??
          (note == null
              ? '运行结果 / 产物'
              : '精读证据 · ${note.$1.relativePath}'
                    '${note.$2.pageNumber == null ? '' : ' · p. ${note.$2.pageNumber}'}');
      return ListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        leading: Icon(
          entry != null
              ? Icons.fact_check_outlined
              : note != null
              ? Icons.format_quote_outlined
              : Icons.analytics_outlined,
        ),
        title: Text(
          entry == null
              ? title
              : '${recordKinds[entry.kind] ?? entry.kind} · $title',
        ),
        subtitle: note != null && note.$2.quote.isNotEmpty
            ? Text('“${note.$2.quote}”', maxLines: 2)
            : SelectableText(id, style: const TextStyle(fontSize: 11)),
        onTap: entry != null
            ? () => widget.onShowEntry(entry)
            : note != null
            ? () => widget.onOpenDocument(note.$1)
            : () => Clipboard.setData(ClipboardData(text: id)),
        trailing: IconButton(
          tooltip: '移除此证据',
          icon: const Icon(Icons.link_off, size: 18),
          onPressed: () => _guard(() => store.removeOutline('${link['id']}')),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('证据驱动的论文提纲', style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                const Text(
                  '段落可分层、排序，写明论述并标注证据支持程度。从主张、精读笔记或已接纳运行关联证据。导出报告按段落顺序保留证据来源。',
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: widget.onExportReport,
              icon: const Icon(Icons.description_outlined),
              label: const Text('导出 Markdown 研究报告'),
            ),
            OutlinedButton.icon(
              onPressed: () => _edit(),
              icon: const Icon(Icons.add),
              label: const Text('新增段落'),
            ),
            OutlinedButton(
              onPressed: widget.onPickEvidence,
              child: const Text('选择主张与证据'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        for (final (i, section) in sections.indexed)
          Padding(
            padding: EdgeInsets.only(
              left: 24.0 * (section.level - 1),
              bottom: 12,
            ),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 10, 8, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 6, right: 10),
                      child: Text(
                        section.heading,
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                    // Wraps on narrow phones instead of overflowing.
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 4,
                      children: [
                        Chip(label: Text(sectionSupport[section.support]!)),
                        IconButton(
                          tooltip: '上移',
                          onPressed: i == 0
                              ? null
                              : () => _guard(
                                  () => store.moveSection(section.id, -1),
                                ),
                          icon: const Icon(Icons.arrow_upward, size: 18),
                        ),
                        IconButton(
                          tooltip: '下移',
                          onPressed: i == sections.length - 1
                              ? null
                              : () => _guard(
                                  () => store.moveSection(section.id, 1),
                                ),
                          icon: const Icon(Icons.arrow_downward, size: 18),
                        ),
                        IconButton(
                          tooltip: '编辑段落',
                          onPressed: () => _edit(section),
                          icon: const Icon(Icons.edit_outlined, size: 18),
                        ),
                        IconButton(
                          tooltip: '删除段落',
                          onPressed: () => _delete(section),
                          icon: const Icon(Icons.delete_outline, size: 18),
                        ),
                      ],
                    ),
                    if (section.argument.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: SelectableText(section.argument),
                      ),
                    for (final link in links.where(
                      (l) => l['section_id'] == section.id,
                    ))
                      evidenceTile(link),
                    if (!links.any((l) => l['section_id'] == section.id))
                      const Text('尚无证据。'),
                  ],
                ),
              ),
            ),
          ),
        if (sections.isEmpty) const Text('提纲尚未建立。新增段落，或从主张、笔记、已接纳结果关联证据。'),
      ],
    );
  }
}
