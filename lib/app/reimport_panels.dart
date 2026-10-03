import 'package:flutter/material.dart';

import '../core/exchange.dart';
import '../core/models.dart';

/// Re-import UI (docs/research-skill-integration.md §8).

/// Asks whether [path] becomes a new project or the next snapshot of an
/// existing one. Returns null on cancel, '' for a new project, else the id.
Future<String?> chooseImportTarget(
  BuildContext context,
  String path,
  List<ResearchProject> projects,
) {
  var target = '';
  return showDialog<String>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, update) => AlertDialog(
        title: const Text('导入研究快照'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: RadioGroup<String>(
              groupValue: target,
              onChanged: (v) => update(() => target = v ?? ''),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectableText(
                    '将所选材料复制到工作台私有资料库，原目录保持不变。\n$path\n论文、主张和候选保留原有状态。',
                  ),
                  const SizedBox(height: 12),
                  const RadioListTile(value: '', title: Text('新建项目')),
                  for (final p in projects)
                    RadioListTile(
                      value: p.id,
                      title: Text('更新：${p.title}'),
                      subtitle: const Text('作为新快照导入；笔记和提纲按路径与修订迁移，旧快照保留'),
                    ),
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, target),
            child: const Text('导入'),
          ),
        ],
      ),
    ),
  );
}

Future<void> showReimportSummary(
  BuildContext context,
  ReimportSummary s,
) => showDialog<void>(
  context: context,
  builder: (c) => AlertDialog(
    title: const Text('已更新为新快照'),
    content: SelectableText(
      [
        '笔记：迁移 ${s.notesMoved} 条'
            '${s.notesNeedReview == 0 ? '' : '，其中 ${s.notesNeedReview} 条所在文件内容已变，标为待复核'}。',
        if (s.notesLeft > 0)
          '${s.notesLeft} 条笔记的文件在新快照中不存在，留在旧快照，可在概览“未迁移笔记”查看。',
        '提纲：迁移 ${s.outlineMoved} 处'
            '${s.outlineLeft == 0 ? '' : '，${s.outlineLeft} 处在新快照中找不到同一修订，仍指向旧快照'}。',
        if (s.bindingsKept > 0) '沿用 ${s.bindingsKept} 个人工确认的论文绑定。',
        '旧快照及其文件保留，不会删除。',
      ].join('\n'),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(c), child: const Text('知道了')),
    ],
  ),
);

/// Notes left on documents that the current snapshot no longer contains.
class UnmigratedNotes extends StatelessWidget {
  const UnmigratedNotes({super.key, required this.notes, required this.onOpen});
  final List<(ResearchDocument, ReadingNote)> notes;
  final void Function(ResearchDocument) onOpen;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text('这些笔记的文件在最新导入中不存在，仍保存在旧快照里，可打开旧文件继续查看。'),
      for (final (doc, note) in notes)
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(note.text, maxLines: 2, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            [
              doc.relativePath,
              if (note.pageNumber != null) 'p. ${note.pageNumber}',
            ].join(' · '),
          ),
          trailing: TextButton(
            onPressed: () => onOpen(doc),
            child: const Text('打开旧文件'),
          ),
        ),
    ],
  );
}
