import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:path/path.dart' as p;
import '../core/models.dart';
import '../core/store.dart';
import '../core/exchange.dart';
import '../core/research_skill.dart';
import '../reader/reader_page.dart';
import '../relations/relations_page.dart';
import 'lan_transfer_page.dart';
import 'skill_panels.dart';
import 'theme.dart';

class WorkbenchApp extends StatelessWidget {
  const WorkbenchApp({
    super.key,
    required this.store,
    this.loadMarkdown,
    this.pickImportFile,
    this.saveExportFile,
  });
  final WorkbenchStore store;
  final Future<String> Function(String path)? loadMarkdown;
  final Future<String?> Function(List<String> extensions)? pickImportFile;
  final Future<Uri?> Function(String name, Uint8List bytes, String mimeType)?
  saveExportFile;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '研究工作台',
    debugShowCheckedModeBanner: false,
    theme: workbenchTheme(),
    darkTheme: workbenchTheme(dark: true),
    themeMode: ThemeMode.system,
    locale: const Locale('zh'),
    supportedLocales: const [Locale('zh'), Locale('en')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    home: WorkbenchHome(
      store: store,
      loadMarkdown: loadMarkdown,
      pickImportFile: pickImportFile,
      saveExportFile: saveExportFile,
    ),
  );
}

class WorkbenchHome extends StatefulWidget {
  const WorkbenchHome({
    super.key,
    required this.store,
    this.loadMarkdown,
    this.pickImportFile,
    this.saveExportFile,
  });
  final WorkbenchStore store;
  final Future<String> Function(String path)? loadMarkdown;
  final Future<String?> Function(List<String> extensions)? pickImportFile;
  final Future<Uri?> Function(String name, Uint8List bytes, String mimeType)?
  saveExportFile;
  @override
  State<WorkbenchHome> createState() => _WorkbenchHomeState();
}

class _WorkbenchHomeState extends State<WorkbenchHome> {
  int section = 0;
  String? projectId;
  bool busy = false;
  String search = '';
  String entryKind = 'papers';
  bool showRetired = false;
  String? lastExportPath;
  static const labels = ['概览', '文库与证据', '研究任务', '运行结果', '论文写作', '研究关系'];
  static const icons = [
    Icons.space_dashboard_outlined,
    Icons.menu_book_outlined,
    Icons.assignment_outlined,
    Icons.analytics_outlined,
    Icons.edit_note_outlined,
    Icons.device_hub_outlined,
  ];
  WorkbenchStore get store => widget.store;
  ResearchProject? get project {
    final all = store.projects();
    if (all.isEmpty) return null;
    return all.firstWhere((p) => p.id == projectId, orElse: () => all.first);
  }

  void refresh() => setState(() {});
  void message(String value) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(value)));
  }

  Future<void> action(Future<void> Function() fn) async {
    setState(() => busy = true);
    try {
      await fn();
      if (mounted) refresh();
    } catch (e) {
      message('操作未完成：$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<bool> confirm(String title, String description) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: SelectableText(description),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认'),
            ),
          ],
        ),
      ) ??
      false;
  Future<String?> pickFile(List<String> extensions) async {
    if (widget.pickImportFile != null) {
      return widget.pickImportFile!(extensions);
    }
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: extensions,
    );
    return files.isEmpty ? null : files.first.path;
  }

  Future<void> importResearch(bool folder) async {
    final path = folder
        ? await FilePicker.getDirectoryPath(
            dialogTitle: '选择 research-workflow 研究目录',
          )
        : await pickFile(['zip']);
    if (path == null || !mounted) return;
    if (!await confirm(
      '导入研究快照',
      '将所选材料复制到工作台私有资料库，原目录保持不变。\n$path\n论文、主张和候选保留原有状态。',
    )) {
      return;
    }
    await action(() async {
      final exchange = ResearchExchange(store);
      final p = await exchange.importResearch(path);
      projectId = p.id;
      section = 0;
      final (files, bytes) = exchange.lastSkipped;
      message(
        p.isSkill
            ? '已导入 research-skill 项目 ${p.title}'
                  '${files == 0 ? '' : '；跳过 $files 个文件（${(bytes / 1048576).toStringAsFixed(1)} MiB：源码包、数据集、权重等）'}'
            : '已导入 ${p.title}',
      );
    });
  }

  String get exportDirectory => p.join(store.rootPath, 'exports');

  Future<void> saveGenerated(String path, String mimeType) async {
    lastExportPath = path;
    final bytes = Uint8List.fromList(await File(path).readAsBytes());
    final name = p.basename(path);
    final uri =
        await (widget.saveExportFile?.call(name, bytes, mimeType) ??
            FilePicker.saveFile(
              fileName: name,
              bytes: bytes,
              mimeType: mimeType,
            ));
    if (uri != null) {
      message('已保存到 ${uri.toString()}');
    } else {
      message('已取消保存；生成的文件仍在本机资料库。');
    }
  }

  Future<void> importTask() async {
    final path = await pickFile(['zip']);
    if (path == null || !mounted) return;
    if (!await confirm('导入任务包', '读取任务规格并保留原包，不会执行其中的命令。\n$path')) {
      return;
    }
    await action(() async {
      final task = await ResearchExchange(store).importTask(path);
      projectId = task.projectId;
      section = 2;
      message('已导入任务 ${task.title} · r${task.revision}');
    });
  }

  Future<void> importResult() async {
    final path = await pickFile(['json', 'zip']);
    if (path == null || !mounted) return;
    if (!await confirm('导入运行结果', '导入后先进入待接纳列表；命令仅作记录，不会执行。\n$path')) return;
    await action(() async {
      final run = await ResearchExchange(store).importResult(path);
      section = 3;
      message('已导入运行 ${run.id}，等待关联为证据');
    });
  }

  Future<void> importLanFile(String path, String kind) async {
    final exchange = ResearchExchange(store);
    if (kind == 'task') {
      final task = await exchange.importTask(path);
      if (mounted) {
        setState(() {
          projectId = task.projectId;
          section = 2;
        });
      }
    } else if (kind == 'result') {
      final run = await exchange.importResult(path);
      final task = store.taskRevision(run.taskId, run.taskRevision)!;
      if (mounted) {
        setState(() {
          projectId = task.projectId;
          section = 3;
        });
      }
    } else if (kind == 'research') {
      final project = await exchange.importResearch(path);
      if (mounted) {
        setState(() {
          projectId = project.id;
          section = 0;
        });
      }
    } else {
      throw const FormatException('Unknown received content type');
    }
    message('局域网文件已导入本机资料库。');
  }

  Future<void> openLan() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => LanTransferPage(
          rootPath: store.rootPath,
          suggestedFile: lastExportPath,
          onImport: importLanFile,
        ),
      ),
    );
    if (mounted) refresh();
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 720;
    final all = store.projects();
    return Scaffold(
      appBar: AppBar(
        title: Text(wide ? '研究工作台 · ${labels[section]}' : labels[section]),
        actions: [
          IconButton(
            tooltip: '局域网传输',
            onPressed: openLan,
            icon: const Icon(Icons.wifi_tethering_outlined),
          ),
          PopupMenuButton<String>(
            tooltip: '导入材料',
            onSelected: (v) => switch (v) {
              'result' => importResult(),
              'task' => importTask(),
              _ => importResearch(v == 'folder'),
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'folder', child: Text('导入研究目录')),
              PopupMenuItem(value: 'zip', child: Text('导入研究 ZIP')),
              PopupMenuItem(value: 'task', child: Text('导入任务包')),
              PopupMenuItem(value: 'result', child: Text('导入结果包')),
            ],
          ),
        ],
      ),
      body: Row(
        children: [
          if (wide)
            SizedBox(
              width: 210,
              child: Material(
                color: Theme.of(context).navigationRailTheme.backgroundColor,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Padding(
                      padding: EdgeInsets.fromLTRB(20, 20, 16, 16),
                      child: Text(
                        'RESEARCH\n研究工作台',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          height: 1.6,
                        ),
                      ),
                    ),
                    for (var i = 0; i < labels.length; i++)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 3,
                        ),
                        child: ListTile(
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          selected: section == i,
                          selectedTileColor: Theme.of(
                            context,
                          ).colorScheme.primaryContainer,
                          leading: Icon(icons[i]),
                          title: Text(labels[i]),
                          onTap: () => setState(() => section = i),
                        ),
                      ),
                    const Spacer(),
                    const Padding(
                      padding: EdgeInsets.all(20),
                      child: Text(
                        '本地资料库\n文件交换 · 无云依赖',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          Expanded(
            child: Column(
              children: [
                if (all.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                    child: Row(
                      children: [
                        const Icon(Icons.folder_open_outlined, size: 20),
                        const SizedBox(width: 10),
                        Expanded(
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<String>(
                              isExpanded: true,
                              value: project?.id,
                              items: all
                                  .map(
                                    (p) => DropdownMenuItem(
                                      value: p.id,
                                      child: Text(
                                        p.title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  )
                                  .toList(),
                              onChanged: (id) => setState(() => projectId = id),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                if (busy) const LinearProgressIndicator(minHeight: 2),
                Expanded(child: project == null ? empty() : page()),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: section == 5 ? 1 : section,
              onDestinationSelected: (i) => setState(() => section = i),
              destinations: [
                for (var i = 0; i < 5; i++)
                  NavigationDestination(
                    icon: Icon(icons[i]),
                    label: ['概览', '文库', '任务', '结果', '写作'][i],
                  ),
              ],
            ),
    );
  }

  Widget empty() => Center(
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
                    onPressed: busy ? null : () => importResearch(true),
                    icon: const Icon(Icons.create_new_folder_outlined),
                    label: const Text('导入研究目录'),
                  ),
                  OutlinedButton.icon(
                    onPressed: busy ? null : () => importResearch(false),
                    icon: const Icon(Icons.archive_outlined),
                    label: const Text('导入 ZIP'),
                  ),
                  OutlinedButton.icon(
                    onPressed: busy ? null : importTask,
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
  Widget page() => switch (section) {
    0 => overview(),
    1 => library(),
    2 => taskPage(),
    3 => runPage(),
    4 => writing(),
    5 => RelationsPage(
      key: ValueKey(project!.id),
      store: store,
      projectId: project!.id,
    ),
    _ => overview(),
  };
  Widget layout(List<Widget> children) => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      for (final child in children)
        Padding(padding: const EdgeInsets.only(bottom: 16), child: child),
    ],
  );
  Widget card(String title, Widget content, {Widget? trailing}) => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              ?trailing,
            ],
          ),
          const SizedBox(height: 12),
          content,
        ],
      ),
    ),
  );
  Widget overview() {
    final p = project!;
    final entries = store.entries(p.id);
    final docs = store.documents(p.id);
    final readme = docs
        .where((d) => d.relativePath.toLowerCase() == 'readme.md')
        .firstOrNull;
    final handoff = docs
        .where((d) => d.relativePath.toLowerCase() == 'handoff.md')
        .firstOrNull;
    return layout([
      card(
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
                Chip(label: Text('${countKind(entries, 'papers')} 篇文献')),
                Chip(label: Text('${countKind(entries, 'claims')} 条主张')),
                Chip(label: Text('${countKind(entries, 'opportunities')} 个候选')),
                Chip(label: Text('${store.tasks(p.id).length} 个任务')),
              ],
            ),
          ],
        ),
        trailing: TextButton(onPressed: editProject, child: const Text('编辑目标')),
      ),
      card(
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
                    onPressed: () => openDocument(handoff),
                    icon: const Icon(Icons.description_outlined),
                    label: const Text('阅读交接'),
                  ),
                if (readme != null)
                  OutlinedButton(
                    onPressed: () => openDocument(readme),
                    child: const Text('阅读研究摘要'),
                  ),
                FilledButton(
                  onPressed: () => editTask(),
                  child: const Text('创建研究任务'),
                ),
              ],
            ),
          ],
        ),
      ),
      if (p.isSkill)
        card(
          '回写 research-skill',
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                p.layout == 'research-skill-v2'
                    ? '已识别为 research-skill V2 项目。精读笔记可导出为待审 claim 草稿，补全后由 research-skill 追加并校验。'
                    : '已识别为 research-skill V1 项目，仅支持阅读；论文绑定与回写需要 V2 记录。',
              ),
              const SizedBox(height: 12),
              if (p.layout == 'research-skill-v2')
                FilledButton.icon(
                  onPressed: busy ? null : exportDrafts,
                  icon: const Icon(Icons.outbox_outlined),
                  label: const Text('导出回写草稿'),
                ),
            ],
          ),
        ),
      card(
        '从材料到论文',
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            OutlinedButton(
              onPressed: () => setState(() => section = 1),
              child: const Text('1  阅读与精读'),
            ),
            OutlinedButton.icon(
              onPressed: () => setState(() => section = 5),
              icon: const Icon(Icons.device_hub_outlined),
              label: const Text('研究关系'),
            ),
            OutlinedButton(
              onPressed: () => setState(() => section = 2),
              child: const Text('2  任务交接'),
            ),
            OutlinedButton(
              onPressed: () => setState(() => section = 3),
              child: const Text('3  结果与证据'),
            ),
            OutlinedButton(
              onPressed: () => setState(() => section = 4),
              child: const Text('4  论文提纲'),
            ),
          ],
        ),
      ),
    ]);
  }

  /// Current, non-retired records for research-skill projects; raw rows otherwise.
  int countKind(List<ResearchEntry> entries, String kind) {
    final rows = entries.where((e) => e.kind == kind).toList();
    return project!.isSkill
        ? revisionGroups(rows).where((g) => !g.retired).length
        : rows.length;
  }

  Future<void> exportDrafts() async {
    final ids = await pickDraftNotes(context, store, project!.id);
    if (ids == null || ids.isEmpty || !mounted) return;
    await action(() async {
      final result = await ResearchExchange(
        store,
      ).exportClaimDrafts(project!.id, ids, exportDirectory);
      await saveGenerated(result.path, 'application/x-ndjson');
      if (mounted) await showDraftSummary(context, result);
    });
  }

  Future<void> editProject() async {
    final p = project!;
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
      refresh();
    }
    // Controllers remain alive through the dialog's exit animation.
  }

  void openDocument(ResearchDocument d) => Navigator.of(context)
      .push(
        MaterialPageRoute<void>(
          builder: (_) => ReaderPage(
            store: store,
            document: d,
            onChanged: refresh,
            loadMarkdown: widget.loadMarkdown,
          ),
        ),
      )
      .then((_) {
        if (mounted) refresh();
      });
  Widget library() {
    final p = project!;
    final docs = store
        .documents(p.id)
        .where(
          (d) => d.relativePath.toLowerCase().contains(search.toLowerCase()),
        )
        .toList();
    // research-skill logs are append-only: show one current row per identity.
    final rows = store.entries(p.id, kind: entryKind);
    final groups =
        (p.isSkill
                ? revisionGroups(rows)
                : rows.map((e) => RevisionGroup([e])).toList())
            .where((g) => !p.isSkill || showRetired || !g.retired)
            .where(
              (g) => '${g.current.title} ${jsonEncode(g.current.data)}'
                  .toLowerCase()
                  .contains(search.toLowerCase()),
            )
            .toList();
    return layout([
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
          onPressed: () => setState(() => section = 5),
          icon: const Icon(Icons.device_hub_outlined),
          label: const Text('查看研究关系'),
        ),
      ),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final kind in [
            ...skillKinds.where(
              (k) => p.isSkill || skillKindLabels.keys.take(4).contains(k),
            ),
            'documents',
          ])
            ChoiceChip(
              label: Text(skillKindLabels[kind] ?? '文件'),
              selected: entryKind == kind,
              onSelected: (_) => setState(() => entryKind = kind),
            ),
          if (p.isSkill && entryKind != 'documents')
            FilterChip(
              label: const Text('显示已退役'),
              selected: showRetired,
              onSelected: (v) => setState(() => showRetired = v),
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
              onTap: () => openDocument(d),
            ),
          ),
        )
      else
        ...groups.map(
          (g) => Card(
            child: ListTile(
              title: Text(g.current.title),
              subtitle: Text(
                [
                  if (p.isSkill) ...revisionBadges(g),
                  entrySubtitle(g.current),
                ].where((s) => s.isNotEmpty).join(' · '),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => showEntry(g.current, group: p.isSkill ? g : null),
            ),
          ),
        ),
      if ((entryKind == 'documents' ? docs : groups).isEmpty)
        const Text('此分类尚无记录。导入文件的原始快照已保留。'),
    ]);
  }

  String entrySubtitle(ResearchEntry e) {
    final d = e.data;
    return [
      d['year'],
      d['venue'],
      d['reading_depth'],
      d['review_status'],
      d['status'],
      d['phase'],
      d['basis'],
    ].where((v) => v != null).join(' · ');
  }

  Future<void> showEntry(ResearchEntry e, {RevisionGroup? group}) async {
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
                Text(
                  [
                    if (group != null) ...revisionBadges(group),
                    entrySubtitle(e),
                  ].where((s) => s.isNotEmpty).join(' · '),
                ),
                const SizedBox(height: 12),
                if (project!.isSkill && e.kind == 'papers') ...[
                  PaperBindingSection(
                    store: store,
                    paper: e,
                    onOpen: (doc) {
                      Navigator.pop(context);
                      openDocument(doc);
                    },
                    onConfirm: (b) {
                      store.confirmBinding(b.documentId, b.paperId);
                      Navigator.pop(context);
                      refresh();
                      message('已确认绑定');
                    },
                  ),
                  const SizedBox(height: 12),
                ],
                if (d['statement'] != null) SelectableText('${d['statement']}'),
                if (d['locator'] != null)
                  SelectableText(
                    '证据定位\n${const JsonEncoder.withIndent('  ').convert(d['locator'])}',
                  ),
                if (d['doi'] != null || d['url'] != null)
                  SelectableText(
                    'DOI / 原文地址\n${d['doi'] ?? ''}\n${d['url'] ?? ''}',
                  ),
                const SizedBox(height: 12),
                const Text('原始记录（状态按来源保留）'),
                const SizedBox(height: 8),
                SelectableText(
                  const JsonEncoder.withIndent('  ').convert(d),
                  style: const TextStyle(fontSize: 12),
                ),
                if (group != null && group.older.isNotEmpty)
                  RevisionHistory(older: group.older),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('关闭'),
          ),
          OutlinedButton(
            onPressed: () {
              Navigator.pop(c);
              linkEvidence(e.id);
            },
            child: const Text('关联论文提纲'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(c);
              findSource(e);
            },
            child: const Text('打开本地阅读材料'),
          ),
        ],
      ),
    );
  }

  void findSource(ResearchEntry e) {
    final all = store.documents(project!.id);
    final bound = store
        .bindings(project!.id)
        .where((b) => !b.ambiguous && b.paperId == sourceIdOf(e))
        .map((b) => all.where((d) => d.id == b.documentId).firstOrNull)
        .nonNulls
        .firstOrNull;
    if (e.kind == 'papers' && bound != null) {
      openDocument(bound);
      return;
    }
    final slug = '${e.data['work_id'] ?? ''}';
    final matches = all
        .where((d) => slug.isNotEmpty && d.relativePath.contains('/$slug/'))
        .toList();
    final md = matches.where((d) => !d.isPdf).firstOrNull;
    if (matches.isEmpty) {
      message('此记录没有匹配的本地正文；可在文件分类阅读已有材料。');
      setState(() => entryKind = 'documents');
    } else {
      openDocument(
        matches.where((d) => d.isPdf).firstOrNull ?? md ?? matches.first,
      );
    }
  }

  Widget taskPage() {
    final tasks = store.tasks(project!.id);
    return layout([
      Wrap(
        spacing: 12,
        runSpacing: 8,
        children: [
          FilledButton.icon(
            onPressed: () => editTask(),
            icon: const Icon(Icons.add),
            label: const Text('创建研究 / 实验任务'),
          ),
          OutlinedButton.icon(
            onPressed: importResult,
            icon: const Icon(Icons.file_download_outlined),
            label: const Text('导入运行结果'),
          ),
          OutlinedButton.icon(
            onPressed: importTask,
            icon: const Icon(Icons.archive_outlined),
            label: const Text('导入任务包'),
          ),
        ],
      ),
      const Text('任务导出为离线包。另一台设备按说明执行，再填写结果包带回。工作台不会执行包内命令。'),
      ...tasks.map(
        (t) => card(
          '${t.title} · r${t.revision}',
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t.goal),
              const SizedBox(height: 8),
              SelectableText(
                '任务 ID：${t.id}',
                style: const TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: () => editTask(t),
                    child: const Text('编辑并保存新修订'),
                  ),
                  OutlinedButton(
                    onPressed: () async {
                      if (await confirm(
                        '开始执行记录',
                        '请先核对任务规格、代码、数据和环境。工作台只记录状态；执行命令需要你在可信工具中明确启动。',
                      )) {
                        store.startManualRun(t);
                        setState(() => section = 3);
                        message('执行记录已开始；在外部工具运行后填写状态与结果。');
                      }
                    },
                    child: const Text('开始执行记录'),
                  ),
                  FilledButton.icon(
                    onPressed: () async {
                      await action(() async {
                        final path = await ResearchExchange(
                          store,
                        ).exportTask(t, exportDirectory);
                        await saveGenerated(path, 'application/zip');
                      });
                    },
                    icon: const Icon(Icons.upload_file_outlined),
                    label: const Text('导出离线任务包'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      if (tasks.isEmpty) const Text('尚无任务。将候选的问题、实验参数和预期结果写入第一份任务规格。'),
    ]);
  }

  Future<void> editTask([ResearchTask? existing]) async {
    final t = TextEditingController(text: existing?.title ?? '');
    final goal = TextEditingController(text: existing?.goal ?? '');
    final spec = TextEditingController(
      text: const JsonEncoder.withIndent('  ').convert(
        existing?.spec ??
            {
              'parameters': <String, dynamic>{},
              'dataReferences': <String>[],
              'codeReference': '',
              'environment': '',
              'expectedResults': <String>['metrics.json', 'run.log'],
              'command': '',
            },
      ),
    );
    String? error;
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setDialog) => AlertDialog(
          title: Text(existing == null ? '新建任务规格' : '保存任务新修订'),
          content: SizedBox(
            width: 700,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: t,
                    decoration: const InputDecoration(labelText: '任务名称'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: goal,
                    minLines: 2,
                    maxLines: 4,
                    decoration: const InputDecoration(labelText: '问题与预期结论范围'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: spec,
                    minLines: 10,
                    maxLines: 18,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                    decoration: InputDecoration(
                      labelText: '参数、数据、代码、环境与预期产物（JSON）',
                      errorText: error,
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                try {
                  final parsed = jsonDecode(spec.text);
                  if (parsed is! Map<String, dynamic>) {
                    throw const FormatException('规格须是 JSON 对象');
                  }
                  if (t.text.trim().isEmpty || goal.text.trim().isEmpty) {
                    throw const FormatException('名称和目标不能为空');
                  }
                  Navigator.pop(c, parsed);
                } catch (e) {
                  setDialog(() => error = '$e');
                }
              },
              child: const Text('保存规格'),
            ),
          ],
        ),
      ),
    );
    if (result != null) {
      store.saveTask(
        id: existing?.id,
        projectId: project!.id,
        title: t.text.trim(),
        goal: goal.text.trim(),
        spec: result,
      );
      refresh();
    }
  }

  Widget comparisonCard(List<ResearchRun> comparable) {
    final task = store.taskRevision(
      comparable.first.taskId,
      comparable.first.taskRevision,
    )!;
    final metricKeys = <String>{
      for (final run in comparable)
        for (final key in (run.data['metrics'] as Map? ?? {}).keys)
          key.toString(),
    }.toList()..sort();
    String metric(ResearchRun run, String key) {
      final metrics = run.data['metrics'];
      if (metrics is! Map || !metrics.containsKey(key)) return '—';
      final value = metrics[key];
      return value is Map || value is List ? jsonEncode(value) : '$value';
    }

    DataRow row(String label, String Function(ResearchRun) value) => DataRow(
      cells: [
        DataCell(Text(label)),
        for (final run in comparable)
          DataCell(
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220),
              child: Text(
                value(run),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
      ],
    );

    return card(
      '同任务结果比较 · ${task.title} · r${task.revision}',
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('不自动判断优劣或科学有效性'),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columns: [
                const DataColumn(label: Text('字段')),
                for (final run in comparable)
                  DataColumn(label: Text('运行 ${run.id.substring(0, 8)}')),
              ],
              rows: [
                row('执行状态', (run) => run.status),
                row('证据接纳', (run) => run.accepted ? '已接纳' : '待接纳'),
                for (final key in metricKeys)
                  row('指标 · $key', (run) => metric(run, key)),
                row('结论', (run) => '${run.data['conclusion'] ?? '—'}'),
                row(
                  '产物数',
                  (run) => '${(run.data['artifacts'] as List?)?.length ?? 0}',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget runPage() {
    final runs = store.runs(project!.id);
    final grouped = <(String, int), List<ResearchRun>>{};
    for (final run in runs) {
      grouped.putIfAbsent((run.taskId, run.taskRevision), () => []).add(run);
    }
    return layout([
      Align(
        alignment: Alignment.centerLeft,
        child: FilledButton.icon(
          onPressed: importResult,
          icon: const Icon(Icons.download_outlined),
          label: const Text('导入 JSON / ZIP 结果包'),
        ),
      ),
      const Text('运行结果先保留原始记录。确认关联为证据表示纳入本项目分析，不代表科学结论已经验证。'),
      for (final group in grouped.values.where((items) => items.length >= 2))
        comparisonCard(group),
      ...runs.map(
        (run) => card(
          '运行 ${run.id}',
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${run.status} · 任务 r${run.taskRevision} · ${run.accepted ? '已关联证据' : '待接纳'}',
              ),
              SelectableText('Task ID：${run.taskId}'),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 8,
                children: [
                  if (run.data['_localManual'] == true) ...[
                    OutlinedButton(
                      onPressed: () => editRun(run),
                      child: const Text('更新执行记录'),
                    ),
                    FilledButton(
                      onPressed: () => exportRun(run),
                      child: const Text('导出结果包'),
                    ),
                    OutlinedButton(
                      onPressed: () => exportRun(run, chooseArtifacts: true),
                      child: const Text('附加产物并导出'),
                    ),
                  ],
                  if (!run.accepted && run.data['_localManual'] != true)
                    FilledButton(
                      onPressed: () async {
                        if (await confirm(
                          '关联为研究证据',
                          '保留此运行的状态、指标、日志和产物引用，并纳入报告。请先核对它的任务修订和数据来源。',
                        )) {
                          store.acceptRun(run.id);
                          refresh();
                        }
                      },
                      child: const Text('确认关联为证据'),
                    ),
                  if (run.accepted)
                    OutlinedButton(
                      onPressed: () => linkEvidence(run.id),
                      child: const Text('关联论文提纲'),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              ExpansionTile(
                title: const Text('原始运行记录'),
                children: [
                  SelectableText(
                    const JsonEncoder.withIndent('  ').convert(run.data),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      if (runs.isEmpty) const Text('尚无返回结果。离线任务包内提供结果格式说明。'),
    ]);
  }

  Future<void> exportRun(
    ResearchRun run, {
    bool chooseArtifacts = false,
  }) async {
    var paths = <String>[];
    if (chooseArtifacts) {
      final files = await FilePicker.pickFiles(type: FileType.any);
      paths = [
        for (final file in files)
          if (file.path != null) file.path!,
      ];
      if (paths.isEmpty) return;
    }
    await action(() async {
      final path = await ResearchExchange(
        store,
      ).exportResult(run, exportDirectory, artifactPaths: paths);
      await saveGenerated(path, 'application/zip');
    });
  }

  Future<void> editRun(ResearchRun run) async {
    var status = run.status;
    final metrics = TextEditingController(
      text: const JsonEncoder.withIndent(
        '  ',
      ).convert(run.data['metrics'] ?? {}),
    );
    final log = TextEditingController();
    final conclusion = TextEditingController(
      text: '${run.data['conclusion'] ?? ''}',
    );
    String? error;
    final saved = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, update) => AlertDialog(
          title: const Text('更新执行记录'),
          content: SizedBox(
            width: 600,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: status,
                    decoration: const InputDecoration(labelText: '执行状态'),
                    items: const [
                      DropdownMenuItem(value: 'running', child: Text('进行中')),
                      DropdownMenuItem(value: 'completed', child: Text('已完成')),
                      DropdownMenuItem(value: 'failed', child: Text('失败')),
                      DropdownMenuItem(value: 'blocked', child: Text('受阻')),
                    ],
                    onChanged: (value) => status = value ?? status,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: metrics,
                    minLines: 3,
                    maxLines: 7,
                    decoration: InputDecoration(
                      labelText: '指标（JSON）',
                      errorText: error,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: log,
                    minLines: 2,
                    maxLines: 4,
                    decoration: const InputDecoration(labelText: '执行日志'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: conclusion,
                    minLines: 2,
                    maxLines: 4,
                    decoration: const InputDecoration(labelText: '结论 / 待复审'),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                try {
                  final parsed = jsonDecode(metrics.text);
                  if (parsed is! Map<String, dynamic>) {
                    throw const FormatException('指标须为 JSON 对象');
                  }
                  Navigator.pop(c, parsed);
                } catch (e) {
                  update(() => error = '$e');
                }
              },
              child: const Text('保存执行记录'),
            ),
          ],
        ),
      ),
    );
    if (saved != null) {
      store.updateManualRun(
        run.id,
        status: status,
        metrics: saved,
        log: log.text,
        conclusion: conclusion.text,
      );
      refresh();
    }
  }

  Future<void> linkEvidence(String id) async {
    final heading = TextEditingController(text: '研究结果与讨论');
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('关联提纲段落'),
        content: TextField(
          controller: heading,
          decoration: const InputDecoration(labelText: '段落标题'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('关联'),
          ),
        ],
      ),
    );
    if (ok == true && heading.text.trim().isNotEmpty) {
      store.addOutline(project!.id, heading.text.trim(), id);
      refresh();
      message('已关联论文提纲');
    }
  }

  Widget writing() {
    final p = project!;
    final outline = store.outline(p.id);
    final entries = store.entries(p.id);
    final noteEvidence = <String, (ResearchDocument, ReadingNote)>{
      for (final doc in store.documents(p.id))
        for (final note in store.notes(doc.id)) note.id: (doc, note),
    };
    return layout([
      card(
        '证据驱动的论文提纲',
        const Text('从主张详情或已接纳运行中选择证据，关联到段落。导出报告保留证据来源和状态，方便继续写作与复审。'),
      ),
      Wrap(
        spacing: 12,
        runSpacing: 8,
        children: [
          FilledButton.icon(
            onPressed: () async {
              await action(() async {
                final path = await ResearchExchange(
                  store,
                ).exportReport(p.id, exportDirectory);
                await saveGenerated(path, 'text/markdown');
              });
            },
            icon: const Icon(Icons.description_outlined),
            label: const Text('导出 Markdown 研究报告'),
          ),
          OutlinedButton(
            onPressed: () => setState(() {
              section = 1;
              entryKind = 'claims';
            }),
            child: const Text('选择主张与证据'),
          ),
        ],
      ),
      ...outline.map((row) {
        final id = '${row['evidence_id'] ?? row['evidenceId'] ?? ''}';
        final e = entries.where((e) => e.id == id).firstOrNull;
        final note = noteEvidence[id];
        return card(
          '${row['heading']}',
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                e?.title ??
                    (note == null
                        ? '运行结果 / 产物'
                        : '精读证据 · ${note.$1.relativePath}'
                              '${note.$2.pageNumber == null ? '' : ' · p. ${note.$2.pageNumber}'}'),
              ),
              SelectableText(id),
              if (note != null && note.$2.quote.isNotEmpty)
                SelectableText('“${note.$2.quote}”'),
              if (e != null)
                TextButton(
                  onPressed: () => showEntry(e),
                  child: const Text('查看证据'),
                ),
              if (note != null)
                TextButton(
                  onPressed: () => openDocument(note.$1),
                  child: const Text('打开精读来源'),
                ),
              IconButton(
                tooltip: '复制证据 ID',
                onPressed: () => Clipboard.setData(ClipboardData(text: id)),
                icon: const Icon(Icons.copy, size: 18),
              ),
            ],
          ),
        );
      }),
      if (outline.isEmpty) const Text('提纲尚未关联证据。先选择一条主张或一份已接纳结果。'),
    ]);
  }
}
