import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/store.dart';
import 'page_common.dart';

/// Project overview: question, next step and the path from material to paper.
class OverviewPage extends StatefulWidget {
  const OverviewPage({
    super.key,
    required this.store,
    required this.projectId,
    required this.onSection,
    required this.onCreateTask,
    required this.onOpenDocument,
  });
  final WorkbenchStore store;
  final String projectId;
  final ValueChanged<int> onSection;
  final VoidCallback onCreateTask;
  final void Function(ResearchDocument) onOpenDocument;

  @override
  State<OverviewPage> createState() => _OverviewPageState();
}

class _OverviewPageState extends State<OverviewPage> {
  WorkbenchStore get store => widget.store;

  @override
  Widget build(BuildContext context) {
    final p = store.projects().firstWhere((x) => x.id == widget.projectId);
    final entries = latestRevisions(store.entries(p.id));
    final docs = currentVersions(store.documents(p.id));
    final readme = docs
        .where((d) => d.relativePath.toLowerCase() == 'readme.md')
        .firstOrNull;
    final handoff = docs
        .where((d) => d.relativePath.toLowerCase() == 'handoff.md')
        .firstOrNull;
    return pageLayout([
      SectionCard(
        '当前研究',
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(p.title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(p.question.isEmpty ? '填写研究问题与目标，让下一步有明确依据。' : p.question),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                Chip(
                  label: Text(
                    '${entries.where((e) => e.kind == 'papers').length} 篇文献',
                  ),
                ),
                Chip(
                  label: Text(
                    '${entries.where((e) => e.kind == 'claims').length} 条主张',
                  ),
                ),
                Chip(
                  label: Text(
                    '${entries.where((e) => e.kind == 'opportunities').length} 个候选',
                  ),
                ),
                Chip(label: Text('${store.tasks(p.id).length} 个任务')),
              ],
            ),
          ],
        ),
        trailing: TextButton(onPressed: editProject, child: const Text('编辑目标')),
      ),
      SectionCard(
        '下一步',
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(p.nextStep.isEmpty ? '从交接说明开始，选择下一项研究任务。' : p.nextStep),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                if (handoff != null)
                  OutlinedButton.icon(
                    onPressed: () => widget.onOpenDocument(handoff),
                    icon: const Icon(Icons.description_outlined),
                    label: const Text('阅读交接'),
                  ),
                if (readme != null)
                  OutlinedButton(
                    onPressed: () => widget.onOpenDocument(readme),
                    child: const Text('阅读研究摘要'),
                  ),
                FilledButton(
                  onPressed: widget.onCreateTask,
                  child: const Text('创建研究任务'),
                ),
              ],
            ),
          ],
        ),
      ),
      SectionCard(
        '从材料到论文',
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            OutlinedButton(
              onPressed: () => widget.onSection(1),
              child: const Text('1  阅读与精读'),
            ),
            OutlinedButton.icon(
              onPressed: () => widget.onSection(5),
              icon: const Icon(Icons.device_hub_outlined),
              label: const Text('研究关系'),
            ),
            OutlinedButton(
              onPressed: () => widget.onSection(2),
              child: const Text('2  任务交接'),
            ),
            OutlinedButton(
              onPressed: () => widget.onSection(3),
              child: const Text('3  结果与证据'),
            ),
            OutlinedButton(
              onPressed: () => widget.onSection(4),
              child: const Text('4  论文提纲'),
            ),
          ],
        ),
      ),
    ]);
  }

  Future<void> editProject() async {
    final p = store.projects().firstWhere((x) => x.id == widget.projectId);
    final question = TextEditingController(text: p.question),
        next = TextEditingController(text: p.nextStep);
    final saved = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('研究问题与下一步'),
        content: SizedBox(
          width: 550,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: question,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(labelText: '研究问题 / 目标'),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: next,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(labelText: '下一步'),
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
            onPressed: () => Navigator.pop(c, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (saved == true) {
      store.saveProject(p.id, question: question.text, nextStep: next.text);
      setState(() {});
    }
    // Controllers remain alive through the dialog's exit animation.
  }
}

/// Welcome screen shown before any project has been imported.
class EmptyWorkbench extends StatelessWidget {
  const EmptyWorkbench({
    super.key,
    required this.busy,
    required this.onImportResearch,
    required this.onImportTask,
  });
  final bool busy;
  final void Function(bool folder) onImportResearch;
  final VoidCallback onImportTask;

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 580),
          child: Column(
            children: [
              Icon(
                Icons.menu_book_outlined,
                size: 58,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 20),
              const Text(
                '让研究材料成为连续的工作',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              const Text(
                '导入文献、主张和候选，在本地阅读与记录。将研究任务带到另一台设备，再把结果带回证据链。',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  FilledButton.icon(
                    onPressed: busy ? null : () => onImportResearch(true),
                    icon: const Icon(Icons.create_new_folder_outlined),
                    label: const Text('导入研究目录'),
                  ),
                  OutlinedButton.icon(
                    onPressed: busy ? null : () => onImportResearch(false),
                    icon: const Icon(Icons.archive_outlined),
                    label: const Text('导入 ZIP'),
                  ),
                  OutlinedButton.icon(
                    onPressed: busy ? null : onImportTask,
                    icon: const Icon(Icons.assignment_outlined),
                    label: const Text('导入任务包'),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              const Text(
                '支持 Markdown、JSONL 与相对附件。源材料不会被修改。',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
