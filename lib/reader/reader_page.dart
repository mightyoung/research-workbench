import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';

import '../core/models.dart';
import '../core/store.dart';
import 'entry_picker.dart';

/// Reads the imported snapshot; notes are separate records, never source edits.
class ReaderPage extends StatefulWidget {
  const ReaderPage({
    super.key,
    required this.store,
    required this.document,
    this.onChanged,
    this.loadMarkdown,
  });
  final WorkbenchStore store;
  final ResearchDocument document;
  final VoidCallback? onChanged;
  final Future<String> Function(String path)? loadMarkdown;

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> {
  final _pdf = PdfViewerController();
  final _locator = TextEditingController();
  final _pageNumber = TextEditingController();
  final _quote = TextEditingController();
  final _note = TextEditingController();
  late final Future<String> _markdown;
  int _page = 1;
  int _pageCount = 0;
  bool _notesVisible = false;
  String? _entryId;

  @override
  void initState() {
    super.initState();
    _markdown = widget.document.isPdf
        ? Future.value('')
        : (widget.loadMarkdown?.call(widget.document.absolutePath) ??
              File(widget.document.absolutePath).readAsString());
  }

  @override
  void dispose() {
    _locator.dispose();
    _pageNumber.dispose();
    _quote.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _showLink(String address) async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('引用地址'),
        content: SelectableText(address),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: address));
              Navigator.pop(context);
            },
            child: const Text('复制地址'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  // Only catalogued local documents from the same imported project may open.
  Future<void> _openLink(String? href) async {
    if (href == null || href.isEmpty) return;
    final uri = Uri.tryParse(href);
    if (uri == null) return;
    if (uri.hasScheme || uri.hasAuthority) {
      await _showLink(href);
      return;
    }
    if (uri.path.isEmpty) {
      _locator.text = uri.fragment;
      setState(() => _notesVisible = true);
      return;
    }
    final target = p.normalize(
      p.join(p.dirname(widget.document.absolutePath), uri.path),
    );
    ResearchDocument? linked;
    for (final doc in widget.store.documents(widget.document.projectId)) {
      if (p.normalize(doc.absolutePath) == target) {
        linked = doc;
        break;
      }
    }
    if (!mounted) return;
    if (linked == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('此引用不在已导入的 Markdown / PDF 文档中。')),
      );
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ReaderPage(
          store: widget.store,
          document: linked!,
          onChanged: widget.onChanged,
          loadMarkdown: widget.loadMarkdown,
        ),
      ),
    );
  }

  Widget _image(Uri uri, String? title, String? alt) {
    // Safe local figures are visible; remote image fetches remain opt-in future work.
    if (!uri.hasScheme && !uri.hasAuthority) {
      var root = widget.document.absolutePath;
      for (final _ in p.split(widget.document.relativePath)) {
        root = p.dirname(root);
      }
      final target = p.normalize(
        p.join(
          p.dirname(widget.document.absolutePath),
          Uri.decodeComponent(uri.path),
        ),
      );
      if (p.isWithin(root, target) &&
          [
            '.png',
            '.jpg',
            '.jpeg',
            '.webp',
            '.gif',
          ].contains(p.extension(target).toLowerCase()) &&
          FileSystemEntity.typeSync(target, followLinks: false) ==
              FileSystemEntityType.file &&
          File(target).lengthSync() <= 30 * 1024 * 1024) {
        return Image.file(
          File(target),
          semanticLabel: alt,
          fit: BoxFit.contain,
          errorBuilder: (_, error, stack) => Text('图片无法解码：${alt ?? uri.path}'),
        );
      }
    }
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.image_outlined, size: 18),
          const SizedBox(width: 8),
          Flexible(child: Text(alt?.isNotEmpty == true ? alt! : '图片引用：$uri')),
        ],
      ),
    );
  }

  void _saveNote() {
    if (_note.text.trim().isEmpty) return;
    try {
      final typedPage = _pageNumber.text.trim();
      final pageNumber = typedPage.isEmpty
          ? (widget.document.isPdf ? _page : null)
          : int.tryParse(typedPage);
      if (typedPage.isNotEmpty && pageNumber == null) {
        throw const FormatException('页码须为正整数');
      }
      if (pageNumber != null &&
          (pageNumber < 1 ||
              (widget.document.isPdf &&
                  _pageCount > 0 &&
                  pageNumber > _pageCount))) {
        throw const FormatException('页码超出文档范围');
      }
      widget.store.saveNote(
        widget.document.id,
        _locator.text.trim(),
        _note.text.trim(),
        pageNumber: pageNumber,
        quote: _quote.text,
        entryId: _entryId,
      );
      _note.clear();
      _quote.clear();
      widget.onChanged?.call();
      setState(() {});
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('精读笔记已保存')));
    } catch (error) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('保存失败：$error')));
    }
  }

  Future<void> _linkNote(ReadingNote note) async {
    var heading = '研究结果与讨论';
    final linked = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('关联提纲段落'),
        content: TextFormField(
          initialValue: heading,
          onChanged: (value) => heading = value,
          decoration: const InputDecoration(labelText: '段落标题'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('关联'),
          ),
        ],
      ),
    );
    if (linked == true && heading.trim().isNotEmpty) {
      widget.store.addOutline(
        widget.document.projectId,
        heading.trim(),
        note.id,
      );
      widget.onChanged?.call();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('精读证据已关联提纲')));
      }
    }
  }

  Future<void> _linkEntry(ReadingNote note, List<ResearchEntry> targets) async {
    final picked = await pickNoteEntry(context, targets, note.entryId);
    if (picked == null) return;
    widget.store.setNoteEntry(note.id, picked.id);
    widget.onChanged?.call();
    if (mounted) setState(() {});
  }

  Widget _notes() {
    final notes = widget.store.notes(widget.document.id);
    final all = widget.store.entries(widget.document.projectId);
    final targets = noteTargets(all);
    final byId = {for (final e in all) e.id: e};
    final entries = widget.store.entries(widget.document.projectId).where((
      entry,
    ) {
      // Evidence metadata can reference a path anywhere in nested JSON.
      return jsonEncode(entry.data).contains(widget.document.relativePath);
    }).toList();
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text('来源与精读', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        SelectableText(
          widget.document.relativePath,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        const Text('笔记保存在本机，原始文档快照保持不变。'),
        if (entries.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('关联记录', style: Theme.of(context).textTheme.titleSmall),
          for (final entry in entries.take(8))
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.title,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    Text(
                      '${entry.kind} · ${entry.id}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      title: const Text('查看来源元数据'),
                      children: [
                        SelectableText(
                          const JsonEncoder.withIndent(
                            '  ',
                          ).convert(entry.data),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
        ],
        const SizedBox(height: 20),
        TextField(
          controller: _locator,
          decoration: const InputDecoration(
            labelText: '证据定位',
            hintText: '页码、章节或原文引句',
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _pageNumber,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: '页码（可选）',
            hintText: 'PDF 可点击“记录当前页”自动填写',
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _quote,
          minLines: 2,
          maxLines: 5,
          decoration: const InputDecoration(
            labelText: '原文引句（可选）',
            hintText: '人工粘贴原文，便于复审核对',
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _note,
          minLines: 3,
          maxLines: 7,
          decoration: const InputDecoration(
            labelText: '精读笔记 / 批注',
            hintText: '记录解释、疑问或支持主张的证据',
          ),
        ),
        const SizedBox(height: 12),
        EntryPicker(
          entries: targets,
          value: _entryId,
          onChanged: (v) => setState(() => _entryId = v),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _saveNote,
          icon: const Icon(Icons.add),
          label: const Text('保存笔记'),
        ),
        const SizedBox(height: 24),
        Text(
          '已保存笔记 (${notes.length})',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        for (final note in notes.reversed)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (note.locator.isNotEmpty)
                    Text(
                      note.locator,
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  if (note.pageNumber != null) Text('p. ${note.pageNumber}'),
                  if (note.quote.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    SelectableText('“${note.quote}”'),
                  ],
                  const SizedBox(height: 6),
                  SelectableText(note.text),
                  if (byId[note.entryId] case final linked?)
                    Text('关联：${entryLabel(linked)}'),
                  Wrap(
                    spacing: 8,
                    children: [
                      TextButton(
                        onPressed: () => _linkNote(note),
                        child: const Text('关联论文提纲'),
                      ),
                      TextButton(
                        onPressed: () => _linkEntry(note, targets),
                        child: const Text('关联研究对象'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _reading() {
    if (widget.document.isPdf) {
      return Column(
        children: [
          Material(
            color: Theme.of(context).colorScheme.surface,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Row(
                children: [
                  IconButton(
                    tooltip: '上一页',
                    onPressed: _pageCount > 0 && _page > 1
                        ? () => _pdf.goToPage(pageNumber: _page - 1)
                        : null,
                    icon: const Icon(Icons.chevron_left),
                  ),
                  Text('$_page / ${_pageCount == 0 ? '…' : _pageCount}'),
                  IconButton(
                    tooltip: '下一页',
                    onPressed: _pageCount > 0 && _page < _pageCount
                        ? () => _pdf.goToPage(pageNumber: _page + 1)
                        : null,
                    icon: const Icon(Icons.chevron_right),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: '缩小',
                    onPressed: _pageCount > 0 ? () => _pdf.zoomDown() : null,
                    icon: const Icon(Icons.zoom_out),
                  ),
                  IconButton(
                    tooltip: '放大',
                    onPressed: _pageCount > 0 ? () => _pdf.zoomUp() : null,
                    icon: const Icon(Icons.zoom_in),
                  ),
                  IconButton(
                    tooltip: '记录当前页',
                    onPressed: () {
                      _locator.text = 'p. $_page';
                      _pageNumber.text = '$_page';
                      setState(() => _notesVisible = true);
                    },
                    icon: const Icon(Icons.note_add_outlined),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: PdfViewer.file(
              widget.document.absolutePath,
              controller: _pdf,
              params: PdfViewerParams(
                onViewerReady: (document, controller) {
                  if (mounted) {
                    setState(() => _pageCount = document.pages.length);
                  }
                },
                onPageChanged: (page) {
                  if (mounted && page != null) setState(() => _page = page);
                },
              ),
            ),
          ),
        ],
      );
    }
    return FutureBuilder<String>(
      future: _markdown,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(child: Text('无法读取文档：${snapshot.error}'));
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 800),
            child: Markdown(
              data: snapshot.data!,
              selectable: true,
              padding: const EdgeInsets.all(28),
              imageBuilder: _image,
              onTapLink: (text, href, title) => _openLink(href),
              styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context))
                  .copyWith(
                    p: Theme.of(
                      context,
                    ).textTheme.bodyLarge?.copyWith(height: 1.7),
                  ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.document.title),
      actions: [
        IconButton(
          tooltip: _notesVisible ? '返回阅读' : '来源与精读笔记',
          icon: Icon(
            _notesVisible ? Icons.menu_book_outlined : Icons.notes_outlined,
          ),
          onPressed: () => setState(() => _notesVisible = !_notesVisible),
        ),
      ],
    ),
    body: LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth > 1000) {
          return Row(
            children: [
              Expanded(child: _reading()),
              const VerticalDivider(width: 1),
              SizedBox(width: 340, child: _notes()),
            ],
          );
        }
        return IndexedStack(
          index: _notesVisible ? 1 : 0,
          children: [_reading(), _notes()],
        );
      },
    ),
  );
}
