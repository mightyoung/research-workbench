import 'dart:convert';

import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/research_kinds.dart';
import '../core/store.dart';
import 'page_common.dart';

/// Library and evidence: imported records by kind, plus the local files.
class LibraryPage extends StatefulWidget {
  const LibraryPage({
    super.key,
    required this.store,
    required this.projectId,
    required this.entryKind,
    required this.onEntryKindChanged,
    required this.onShowRelations,
    required this.onShowEntry,
    required this.onOpenDocument,
  });
  final WorkbenchStore store;
  final String projectId;
  final String entryKind;
  final ValueChanged<String> onEntryKindChanged;
  final VoidCallback onShowRelations;
  final void Function(ResearchEntry) onShowEntry;
  final void Function(ResearchDocument) onOpenDocument;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  String search = '';
  bool showHistory = false;

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    final entryKind = widget.entryKind;
    final docs = store
        .documents(widget.projectId)
        .where(
          (d) => d.relativePath.toLowerCase().contains(search.toLowerCase()),
        )
        .toList();
    final presentKinds = store
        .entries(widget.projectId)
        .map((e) => e.kind)
        .toSet();
    final allEntries = store.entries(widget.projectId, kind: entryKind);
    final latest = latestRevisions(allEntries);
    final hidden = allEntries.length - latest.length;
    final entries = (showHistory ? allEntries : latest)
        .where(
          (e) => '${e.title} ${jsonEncode(e.data)}'.toLowerCase().contains(
            search.toLowerCase(),
          ),
        )
        .toList();
    return pageLayout([
      TextField(
        onChanged: (v) => setState(() => search = v),
        decoration: const InputDecoration(
          labelText: '搜索文献、主张与文件',
          prefixIcon: Icon(Icons.search),
        ),
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          onPressed: widget.onShowRelations,
          icon: const Icon(Icons.device_hub_outlined),
          label: const Text('查看研究关系'),
        ),
      ),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final kind in [
            ...{...recordKinds.keys, 'other'}.where(
              (k) =>
                  const {
                    'papers',
                    'claims',
                    'opportunities',
                    'experiments',
                  }.contains(k) ||
                  presentKinds.contains(k),
            ),
            'documents',
          ])
            ChoiceChip(
              label: Text(
                recordKinds[kind] ??
                    const {'other': '其他记录', 'documents': '文件'}[kind]!,
              ),
              selected: entryKind == kind,
              onSelected: (_) => widget.onEntryKindChanged(kind),
            ),
          if (entryKind != 'documents' && hidden > 0)
            FilterChip(
              label: Text('显示 $hidden 个历史修订'),
              selected: showHistory,
              onSelected: (v) => setState(() => showHistory = v),
            ),
        ],
      ),
      if (entryKind == 'documents')
        ...docs.map(
          (d) => Card(
            child: ListTile(
              leading: Icon(
                d.isPdf
                    ? Icons.picture_as_pdf_outlined
                    : Icons.description_outlined,
              ),
              title: Text(d.title),
              subtitle: Text(d.relativePath),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => widget.onOpenDocument(d),
            ),
          ),
        )
      else
        ...entries.map(
          (e) => Card(
            child: ListTile(
              title: Text(e.title),
              subtitle: Text(
                entrySubtitle(e),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => widget.onShowEntry(e),
            ),
          ),
        ),
      if ((entryKind == 'documents' ? docs : entries).isEmpty)
        const Text('此分类尚无记录。导入文件的原始快照已保留。'),
    ]);
  }
}

String entrySubtitle(ResearchEntry e) {
  final d = e.data;
  return [
    if (d['rev'] != null) 'r${d['rev']}',
    for (final f in summaryFields) displayValue(fieldValue(d, f)),
    d['year'],
    d['venue'],
    d['reading_depth'],
    d['review_status'],
    d['status'],
    d['basis'],
  ].where((v) => v != null && v != '').join(' · ');
}

/// Labelled judgment fields of a record kind that are present in [d].
List<Widget> judgment(String kind, Map<String, dynamic> d) => [
  for (final MapEntry(key: path, value: label)
      in (judgmentFields[kind] ?? const <String, String>{}).entries)
    if (displayValue(fieldValue(d, path)).isNotEmpty)
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: SelectableText.rich(
          TextSpan(
            children: [
              TextSpan(
                text: '$label　',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              TextSpan(text: displayValue(fieldValue(d, path))),
            ],
          ),
        ),
      ),
];

List<(ResearchDocument, ReadingNote)> notesAbout(
  WorkbenchStore store,
  String projectId,
  String entryId,
) => [
  for (final doc in store.documents(projectId))
    for (final note in store.notes(doc.id))
      if (note.entryId == entryId) (doc, note),
];

Future<void> showEntryDialog(
  BuildContext context, {
  required WorkbenchStore store,
  required String projectId,
  required ResearchEntry entry,
  required void Function(String id) onLinkEvidence,
  required void Function(ResearchEntry plan) onCreateTask,
  required void Function(ResearchEntry e) onFindSource,
  required void Function(ResearchDocument d) onOpenDocument,
}) async {
  final e = entry;
  final d = e.data;
  await showDialog<void>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(e.title),
      content: SizedBox(
        width: 680,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(entrySubtitle(e)),
              const SizedBox(height: 12),
              if (d['statement'] != null) SelectableText('${d['statement']}'),
              const SizedBox(height: 8),
              ...judgment(e.kind, d),
              if (d['locator'] != null)
                SelectableText(
                  '证据定位\n${const JsonEncoder.withIndent('  ').convert(d['locator'])}',
                ),
              if (d['doi'] != null || d['url'] != null)
                SelectableText(
                  'DOI / 原文地址\n${d['doi'] ?? ''}\n${d['url'] ?? ''}',
                ),
              if (notesAbout(store, projectId, e.id) case final linked
                  when linked.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text('相关精读笔记 (${linked.length})'),
                for (final (doc, note) in linked)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    leading: const Icon(Icons.format_quote_outlined),
                    title: Text(
                      note.quote.isEmpty ? note.text : '“${note.quote}”',
                    ),
                    subtitle: Text(
                      '${doc.relativePath}'
                      '${note.pageNumber == null ? '' : ' · p. ${note.pageNumber}'}'
                      '${note.quote.isEmpty ? '' : ' · ${note.text}'}',
                    ),
                    onTap: () {
                      Navigator.pop(c);
                      onOpenDocument(doc);
                    },
                  ),
              ],
              const SizedBox(height: 12),
              const Text('原始记录（状态按来源保留）'),
              const SizedBox(height: 8),
              SelectableText(
                const JsonEncoder.withIndent('  ').convert(d),
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('关闭')),
        OutlinedButton(
          onPressed: () {
            Navigator.pop(c);
            onLinkEvidence(e.id);
          },
          child: const Text('关联论文提纲'),
        ),
        if (e.kind == 'experiments' && d['phase'] != 'executed')
          OutlinedButton(
            onPressed: () {
              Navigator.pop(c);
              onCreateTask(e);
            },
            child: const Text('生成实验任务'),
          ),
        FilledButton(
          onPressed: () {
            Navigator.pop(c);
            onFindSource(e);
          },
          child: const Text('打开本地阅读材料'),
        ),
      ],
    ),
  );
}
