import 'dart:convert';

import 'package:flutter/material.dart';

import '../core/exchange.dart';
import '../core/models.dart';
import '../core/research_skill.dart';
import '../core/store.dart';

/// research-skill specific UI pieces; see docs/research-skill-integration.md.

const skillKindLabels = {
  'papers': '论文',
  'claims': '主张',
  'opportunities': '候选',
  'experiments': '实验计划',
  'tensions': '矛盾与瓶颈',
  'searches': '检索记录',
  'sources': '来源',
  'failures': '失败记录',
  'handoffs': '交接',
};

const _methodLabels = {
  'material_binding': '获取登记 material_binding',
  'arxiv_manifest': 'arXiv 下载 manifest',
};

String bindingMethodLabel(String method) {
  final manual = method.endsWith('+manual');
  final base = manual ? method.substring(0, method.length - 7) : method;
  return '${_methodLabels[base] ?? base}${manual ? '（人工确认）' : ''}';
}

/// Status badges for a revision group, in display order.
/// Row review status only. Method-version hints stay in [methodHintLabels].
List<String> revisionBadges(RevisionGroup g) => [
  if (revOf(g.current) != null) 'r${revOf(g.current)}',
  if (g.older.isNotEmpty) '${g.history.length} 个修订',
  if (g.needsReview) '待复核',
  if (g.duplicate) '修订重复',
  if (g.retired) '已退役',
];

/// Separate copy for a method-version hint, so it is not the row's 待复核 badge.
List<String> methodHintLabels(SkillReviewHint hint) =>
    hint.severity == 'none' || hint.reason.isEmpty ? const [] : [hint.reason];

/// The exact paper revision a binding points at, if imported.
ResearchEntry? boundPaper(
  WorkbenchStore store,
  String projectId,
  PaperBinding b,
) => store
    .entries(projectId, kind: 'papers')
    .where((e) => sourceIdOf(e) == b.paperId && revOf(e) == b.paperRev)
    .firstOrNull;

class RevisionHistory extends StatelessWidget {
  const RevisionHistory({super.key, required this.older});
  final List<ResearchEntry> older;

  @override
  Widget build(BuildContext context) => ExpansionTile(
    tilePadding: EdgeInsets.zero,
    title: Text('修订历史（${older.length} 个较早修订）'),
    children: [
      for (final e in older.reversed)
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: Text('r${revOf(e) ?? '?'} · ${e.data['updated_at'] ?? ''}'),
          subtitle: Text(e.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          children: [
            SelectableText(
              const JsonEncoder.withIndent('  ').convert(e.data),
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
    ],
  );
}

/// Bound material, ambiguous candidates and current claims for a paper.
class PaperBindingSection extends StatelessWidget {
  const PaperBindingSection({
    super.key,
    required this.store,
    required this.paper,
    required this.onOpen,
    required this.onConfirm,
  });
  final WorkbenchStore store;
  final ResearchEntry paper;
  final void Function(ResearchDocument) onOpen;
  final void Function(PaperBinding) onConfirm;

  @override
  Widget build(BuildContext context) {
    final id = sourceIdOf(paper);
    final docs = {for (final d in store.documents(paper.projectId)) d.id: d};
    final bindings = store
        .bindings(paper.projectId)
        .where((b) => b.paperId == id && docs.containsKey(b.documentId))
        .toList();
    final claims =
        revisionGroups(store.entries(paper.projectId, kind: 'claims'))
            .where((g) => !g.retired && '${g.current.data['paper_id']}' == id)
            .map((g) => g.current)
            .toList();
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('本地材料', style: text.titleSmall),
        if (bindings.isEmpty) const Text('未找到绑定的材料文件。'),
        for (final b in bindings)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              b.ambiguous ? Icons.help_outline : Icons.picture_as_pdf_outlined,
            ),
            title: Text(docs[b.documentId]!.relativePath),
            subtitle: Text(
              [
                bindingMethodLabel(b.method),
                '绑定修订 r${b.paperRev}',
                if (!b.hashOk) '文件与登记哈希不符',
                if (b.ambiguous) '多重匹配，待人工选择',
              ].join(' · '),
            ),
            trailing: b.ambiguous
                ? TextButton(
                    onPressed: () => onConfirm(b),
                    child: const Text('确认绑定'),
                  )
                : TextButton(
                    onPressed: () => onOpen(docs[b.documentId]!),
                    child: const Text('打开'),
                  ),
          ),
        const SizedBox(height: 8),
        Text('当前主张（${claims.length}）', style: text.titleSmall),
        for (final c in claims)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('· ${c.title}  [claims/${sourceIdOf(c)}@${revOf(c)}]'),
          ),
      ],
    );
  }
}

/// Lets the user pick notes for a claim draft export. Notes on documents
/// without a confirmed paper binding are listed with the reason and disabled.
Future<List<String>?> pickDraftNotes(
  BuildContext context,
  WorkbenchStore store,
  String projectId,
) {
  final bindings = store.bindings(projectId);
  final rows = <(ReadingNote, ResearchDocument, String?)>[];
  for (final doc in store.documents(projectId)) {
    final found = bindings.where((b) => b.documentId == doc.id).toList();
    final reason = found.isEmpty
        ? '文档未绑定论文'
        : found.every((b) => b.ambiguous)
        ? '文档有多个候选论文，需先确认绑定'
        : null;
    for (final note in store.notes(doc.id)) {
      rows.add((note, doc, reason));
    }
  }
  final selected = {
    for (final r in rows)
      if (r.$3 == null) r.$1.id,
  };
  return showDialog<List<String>>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, update) => AlertDialog(
        title: const Text('导出回写草稿'),
        content: SizedBox(
          width: 620,
          child: rows.isEmpty
              ? const Text('还没有精读笔记。')
              : ListView(
                  shrinkWrap: true,
                  children: [
                    const Text(
                      '选中的笔记将生成 research-skill V2 claim 草稿（review_status: needs_review）。'
                      '工作台不会写入项目日志；请人工或由研究 agent 补全后追加，再运行 check-research.py。',
                    ),
                    const SizedBox(height: 8),
                    for (final (note, doc, reason) in rows)
                      CheckboxListTile(
                        value: selected.contains(note.id),
                        onChanged: reason != null
                            ? null
                            : (v) => update(
                                () => v == true
                                    ? selected.add(note.id)
                                    : selected.remove(note.id),
                              ),
                        title: Text(
                          note.text,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          [
                            doc.relativePath,
                            if (note.pageNumber != null)
                              'p. ${note.pageNumber}',
                            ?reason,
                          ].join(' · '),
                        ),
                      ),
                  ],
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: selected.isEmpty
                ? null
                : () => Navigator.pop(c, selected.toList()),
            child: Text('导出 ${selected.length} 条'),
          ),
        ],
      ),
    ),
  );
}

Future<void> showDraftSummary(BuildContext context, ClaimDraftExport result) =>
    showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('回写草稿已生成'),
        content: SelectableText(
          [
            '导出 ${result.rows.length} 条，跳过 ${result.skipped.length} 条。',
            for (final (_, reason) in result.skipped) '· 跳过：$reason',
            if (result.hashMismatches > 0)
              '${result.hashMismatches} 条来自哈希不符的文件，追加前请核对材料。',
            if (result.missingFields.isNotEmpty)
              '待人工补全：${result.missingFields.join('、')}',
            '建议放在项目根的 workbench-drafts/ 下，不要放进 research/。',
          ].join('\n'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
