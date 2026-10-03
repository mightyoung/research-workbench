import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:path/path.dart' as p;
import '../core/models.dart';
import '../core/store.dart';
import '../core/exchange.dart';
import '../reader/reader_page.dart';
import '../relations/relations_page.dart';
import '../core/skill_bridge.dart';
import 'lan_transfer_page.dart';
import 'library_page.dart';
import 'page_common.dart';
import 'run_page.dart';
import 'task_page.dart';
import 'writing_page.dart';
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
  bool showHistory = false;
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
  void message(String value) => showMessage(context, value);

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

  Future<bool> confirm(String title, String description) =>
      confirmDialog(context, title, description);
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
    final target = await chooseImportTarget(path);
    if (target == null) return;
    await action(() async {
      final p = await ResearchExchange(
        store,
      ).importResearch(path, intoProjectId: target.isEmpty ? null : target);
      projectId = p.id;
      section = 0;
      message(target.isEmpty ? '已导入 ${p.title}' : '已更新 ${p.title}，笔记与提纲保留');
    });
  }

  /// Returns a project ID to refresh, '' for a new project, or null to cancel.
  Future<String?> chooseImportTarget(String path) async {
    final name = p
        .basename(path)
        .replaceFirst(RegExp(r'\.zip$', caseSensitive: false), '');
    final projects = store.projects()
      ..sort((a, b) => (b.title == name ? 1 : 0) - (a.title == name ? 1 : 0));
    if (projects.isEmpty) return '';
    return showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('导入到哪个项目？'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, ''),
            child: Text('新建项目「$name」'),
          ),
          for (final project in projects)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, project.id),
              child: Text(
                '更新「${project.title}」${project.title == name ? ' · 同名' : ''}'
                '\n保留笔记、任务、运行与提纲',
              ),
            ),
        ],
      ),
    );
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

  Future<bool> importLanFile(String path, String kind) async {
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
      final target = await chooseImportTarget(path);
      if (target == null) return false;
      final project = await exchange.importResearch(
        path,
        intoProjectId: target.isEmpty ? null : target,
      );
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
    return true;
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
  Widget overview() {
    final p = project!;
    final entries = latestRevisions(store.entries(p.id));
    final docs = store.documents(p.id);
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
      SectionCard(
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
  Widget library() => LibraryPage(
    store: store,
    projectId: project!.id,
    entryKind: entryKind,
    onEntryKindChanged: (kind) => setState(() => entryKind = kind),
    onShowRelations: () => setState(() => section = 5),
    onShowEntry: showEntry,
    onOpenDocument: openDocument,
  );

  Future<void> showEntry(ResearchEntry e) => showEntryDialog(
    context,
    store: store,
    projectId: project!.id,
    entry: e,
    onLinkEvidence: linkEvidence,
    onCreateTask: createTaskFromPlan,
    onFindSource: findSource,
    onOpenDocument: openDocument,
  );

  void findSource(ResearchEntry e) {
    final all = store.documents(project!.id);
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

  Future<void> exportFile(
    Future<String> Function(String directory) build,
    String mimeType,
  ) =>
      action(() async => saveGenerated(await build(exportDirectory), mimeType));

  Widget taskPage() => TaskPage(
    store: store,
    projectId: project!.id,
    onImportResult: importResult,
    onImportTask: importTask,
    onRunStarted: () {
      setState(() => section = 3);
      message('执行记录已开始；在外部工具运行后填写状态与结果。');
    },
    onExport: exportFile,
  );

  Future<void> editTask() async {
    if (await editTaskDialog(context, store, project!.id)) refresh();
  }

  Widget runPage() => RunPage(
    store: store,
    projectId: project!.id,
    onImportResult: importResult,
    onLinkEvidence: linkEvidence,
    onExport: exportFile,
  );

  void createTaskFromPlan(ResearchEntry plan) {
    try {
      final draft = taskFromExperiment(plan);
      final task = store.saveTask(
        projectId: plan.projectId,
        title: draft.title,
        goal: draft.goal,
        spec: draft.spec,
      );
      setState(() => section = 2);
      message('已生成任务 ${task.title}，可编辑补充代码、数据与环境');
    } on FormatException catch (e) {
      message('未生成任务：${e.message}');
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
    return WritingPage(
      key: ValueKey(p.id),
      store: store,
      projectId: p.id,
      onExportReport: () => action(() async {
        final path = await ResearchExchange(
          store,
        ).exportReport(p.id, exportDirectory);
        await saveGenerated(path, 'text/markdown');
      }),
      onPickEvidence: () => setState(() {
        section = 1;
        entryKind = 'claims';
      }),
      onShowEntry: showEntry,
      onOpenDocument: openDocument,
    );
  }
}
