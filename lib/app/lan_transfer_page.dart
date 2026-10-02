import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../core/lan_transfer.dart';

/// LAN transfer is opt-in. This page never starts a listener in initState.
class LanTransferPage extends StatefulWidget {
  const LanTransferPage({
    super.key,
    required this.rootPath,
    required this.onImport,
    this.suggestedFile,
  });
  final String rootPath;
  final String? suggestedFile;
  final Future<void> Function(String path, String kind) onImport;

  @override
  State<LanTransferPage> createState() => _LanTransferPageState();
}

class _LanTransferPageState extends State<LanTransferPage> {
  final _address = TextEditingController();
  final _code = TextEditingController();
  LanShareSession? _session;
  Timer? _ticker;
  String? _selected;
  String? _received;
  List<String> _addresses = [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (widget.suggestedFile != null &&
        File(widget.suggestedFile!).existsSync()) {
      _selected = widget.suggestedFile;
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    if (_session != null) unawaited(_session!.stop());
    _address.dispose();
    _code.dispose();
    super.dispose();
  }

  void _message(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  Future<void> _chooseFile() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['zip', 'json', 'md', 'markdown', 'pdf'],
    );
    if (files.isNotEmpty && files.first.path != null && mounted) {
      setState(() => _selected = files.first.path);
    }
  }

  Future<void> _start() async {
    final file = _selected;
    if (file == null || _busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('开始局域网共享'),
        content: Text(
          '只共享这一个文件：${p.basename(file)}。同一网络设备需要地址和配对码；10 分钟或成功下载一次后停止。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('开始共享'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final session = await LanShareSession.start(
        file: File(file),
        stagingDirectory: Directory(p.join(widget.rootPath, 'lan-outbox')),
      );
      final addresses = await LanShareSession.localAddresses();
      if (!mounted) {
        await session.stop();
        return;
      }
      setState(() {
        _session = session;
        _addresses = addresses;
      });
      _ticker?.cancel();
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted && _session?.isActive == false) setState(() {});
      });
    } catch (e) {
      _message('共享未启动：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _stop() async {
    await _session?.stop();
    if (mounted) setState(() {});
  }

  Future<void> _receive() async {
    if (_busy) return;
    final url = Uri.tryParse(_address.text.trim());
    if (url == null) {
      _message('请输入局域网地址，例如 http://192.168.1.5:12345');
      return;
    }
    setState(() => _busy = true);
    try {
      final file = await LanTransferReceiver.receive(
        url: url,
        code: _code.text,
        destination: Directory(p.join(widget.rootPath, 'lan-inbox')),
      );
      if (mounted) {
        setState(() => _received = file.path);
        _message('已接收 ${p.basename(file.path)}；选择内容类型后才会导入。');
      }
    } catch (e) {
      _message('接收未完成：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import(String kind) async {
    final file = _received;
    if (file == null) return;
    setState(() => _busy = true);
    try {
      await widget.onImport(file, kind);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      _message('导入未完成：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    return Scaffold(
      appBar: AppBar(title: const Text('局域网文件传输')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text('两台设备须在同一局域网。不同网络请使用导出的 ZIP/JSON 文件人工交换。'),
          const SizedBox(height: 14),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('发送一个文件', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 6),
                  const Text('只有明确点击“开始共享”后才监听；不开放资料库目录。'),
                  const SizedBox(height: 12),
                  SelectableText(
                    _selected == null ? '未选择文件' : p.basename(_selected!),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton(
                        onPressed: _busy || session?.isActive == true
                            ? null
                            : _chooseFile,
                        child: const Text('选择文件'),
                      ),
                      FilledButton(
                        onPressed:
                            _busy ||
                                _selected == null ||
                                session?.isActive == true
                            ? null
                            : _start,
                        child: const Text('开始共享'),
                      ),
                      if (session?.isActive == true)
                        TextButton(onPressed: _stop, child: const Text('停止共享')),
                    ],
                  ),
                  const SizedBox(height: 10),
                  if (session?.isActive != true) const Text('未开启共享'),
                  if (session?.isActive == true) ...[
                    const Text('仅限一次下载；10 分钟后自动停止。'),
                    if (_addresses.isEmpty)
                      const Text('未找到局域网 IPv4 地址，请检查 Wi‑Fi/局域网。'),
                    for (final address in _addresses)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: SelectableText(
                          'http://$address:${session!.port}/transfer',
                        ),
                        trailing: IconButton(
                          tooltip: '复制地址',
                          icon: const Icon(Icons.copy),
                          onPressed: () => Clipboard.setData(
                            ClipboardData(
                              text: 'http://$address:${session.port}/transfer',
                            ),
                          ),
                        ),
                      ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: SelectableText('配对码：${session!.code}'),
                      trailing: IconButton(
                        tooltip: '复制配对码',
                        icon: const Icon(Icons.copy),
                        onPressed: () => Clipboard.setData(
                          ClipboardData(text: session.code),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('接收文件', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _address,
                    decoration: const InputDecoration(
                      labelText: '发送端地址',
                      hintText: 'http://192.168.1.5:12345/transfer',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _code,
                    decoration: const InputDecoration(labelText: '配对码'),
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: _busy ? null : _receive,
                    child: const Text('接收文件'),
                  ),
                  if (_received != null) ...[
                    const SizedBox(height: 12),
                    SelectableText('已接收：${p.basename(_received!)}'),
                    const Text('请确认文件内容类型，再选择导入；不会自动执行命令。'),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton(
                          onPressed: _busy ? null : () => _import('research'),
                          child: const Text('导入阅读材料'),
                        ),
                        OutlinedButton(
                          onPressed: _busy ? null : () => _import('task'),
                          child: const Text('导入任务包'),
                        ),
                        OutlinedButton(
                          onPressed: _busy ? null : () => _import('result'),
                          child: const Text('导入结果包'),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
