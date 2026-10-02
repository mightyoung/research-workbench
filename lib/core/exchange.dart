import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'models.dart';
import 'store.dart';

class ResearchExchange {
  ResearchExchange(this.store);
  final WorkbenchStore store;
  static const maxBytes = 150 * 1024 * 1024,
      maxFileBytes = 30 * 1024 * 1024,
      maxFiles = 10000;
  String _safe(String name) {
    final normalized = name.replaceAll('\\', '/');
    if (p.posix.isAbsolute(normalized) ||
        RegExp(r'^[A-Za-z]:').hasMatch(normalized) ||
        normalized.split('/').contains('..') ||
        normalized.contains('\u0000')) {
      throw FormatException('Unsafe package path: $name');
    }
    final result = p.posix.normalize(normalized);
    if (result == '.' || result.isEmpty) {
      throw FormatException('Empty package path');
    }
    return result;
  }

  Future<Directory> _snapshot(String input, String group) async {
    final dest = Directory(
      p.join(store.rootPath, 'snapshots', group, const Uuid().v4()),
    );
    await dest.create(recursive: true);
    var total = 0, count = 0;
    final seen = <String>{};
    Future<void> write(String name, List<int> bytes) async {
      final safe = _safe(name);
      if (!seen.add(safe)) {
        throw FormatException('Duplicate package path: $safe');
      }
      total += bytes.length;
      count++;
      if (bytes.length > maxFileBytes || total > maxBytes || count > maxFiles) {
        throw const FormatException(
          'Import exceeds file or package size limit',
        );
      }
      final target = File(p.join(dest.path, safe));
      await target.parent.create(recursive: true);
      await target.writeAsBytes(bytes, flush: true);
    }

    try {
      final type = await FileSystemEntity.type(input, followLinks: false);
      if (type == FileSystemEntityType.link) {
        throw const FormatException('Symbolic links are not imported');
      }
      if (type == FileSystemEntityType.directory) {
        await for (final item in Directory(
          input,
        ).list(recursive: true, followLinks: false)) {
          final kind = await FileSystemEntity.type(
            item.path,
            followLinks: false,
          );
          if (kind == FileSystemEntityType.link) {
            throw const FormatException('Symbolic links are not imported');
          }
          if (kind == FileSystemEntityType.file) {
            if (await File(item.path).length() > maxFileBytes) {
              throw const FormatException('File exceeds 30 MiB');
            }
            await write(
              p.relative(item.path, from: input),
              await File(item.path).readAsBytes(),
            );
          }
        }
      } else if (type == FileSystemEntityType.file &&
          input.toLowerCase().endsWith('.zip')) {
        if (await File(input).length() > maxBytes) {
          throw const FormatException('Package exceeds 150 MiB');
        }
        final archive = ZipDecoder().decodeBytes(
          await File(input).readAsBytes(),
          verify: true,
        );
        // Validate declared expanded sizes before requesting decompressed contents.
        var declared = 0, files = 0;
        for (final entry in archive) {
          _safe(entry.name);
          if (entry.isSymbolicLink) {
            throw const FormatException('Symbolic links are not imported');
          }
          if (entry.isFile) {
            declared += entry.size;
            files++;
            if (entry.size > maxFileBytes ||
                declared > maxBytes ||
                files > maxFiles) {
              throw const FormatException('Expanded package exceeds limit');
            }
          }
        }
        for (final entry in archive) {
          if (entry.isFile) {
            await write(entry.name, entry.content as List<int>);
          }
        }
      } else if (type == FileSystemEntityType.file) {
        if (await File(input).length() > maxFileBytes) {
          throw const FormatException('File exceeds 30 MiB');
        }
        await write(p.basename(input), await File(input).readAsBytes());
      } else {
        throw const FormatException('Input does not exist');
      }
      return dest;
    } catch (_) {
      await dest.delete(recursive: true);
      rethrow;
    }
  }

  Future<ResearchProject> importResearch(String directoryOrZipPath) async {
    final snapshot = await _snapshot(directoryOrZipPath, 'research');
    final id = const Uuid().v4();
    final title = p
        .basename(directoryOrZipPath)
        .replaceFirst(RegExp(r'\.zip$', caseSensitive: false), '');
    store.db.execute('BEGIN');
    try {
      store.db.execute('INSERT INTO projects VALUES(?,?,?,?)', [
        id,
        title,
        '',
        '',
      ]);
      await for (final entity in snapshot.list(recursive: true)) {
        if (entity is! File) {
          continue;
        }
        final relative = p.relative(entity.path, from: snapshot.path);
        final ext = p.extension(relative).toLowerCase();
        if (['.md', '.markdown', '.pdf'].contains(ext)) {
          store.db.execute('INSERT INTO documents VALUES(?,?,?,?)', [
            const Uuid().v4(),
            id,
            relative,
            store.storedPath(entity.path),
          ]);
        }
        if (ext == '.jsonl') {
          final base = p.basenameWithoutExtension(relative);
          final kind =
              [
                'papers',
                'claims',
                'opportunities',
                'experiments',
              ].contains(base)
              ? base
              : 'other';
          var line = 0;
          for (final text in const LineSplitter().convert(
            await entity.readAsString(),
          )) {
            line++;
            if (text.trim().isEmpty) {
              continue;
            }
            final value = jsonDecode(text);
            if (value is! Map) {
              throw FormatException('Expected JSON object at $relative:$line');
            }
            final data = Map<String, dynamic>.from(value);
            final recordTitle =
                (data['title'] ??
                        data['claim'] ??
                        data['statement'] ??
                        data['name'] ??
                        data['id'] ??
                        '$base:$line')
                    .toString();
            // Preserve source IDs verbatim in data; local IDs scope imported snapshots.
            store.db.execute('INSERT INTO entries VALUES(?,?,?,?,?)', [
              const Uuid().v4(),
              id,
              kind,
              recordTitle,
              jsonEncode(data),
            ]);
          }
        }
      }
      store.db.execute('COMMIT');
      return ResearchProject(id: id, title: title);
    } catch (_) {
      store.db.execute('ROLLBACK');
      await snapshot.delete(recursive: true);
      rethrow;
    }
  }

  Future<String> _zip(
    Map<String, List<int>> files,
    String destination,
    String name,
  ) async {
    final archive = Archive();
    files.forEach(
      (path, bytes) => archive.addFile(ArchiveFile(path, bytes.length, bytes)),
    );
    await Directory(destination).create(recursive: true);
    final file = File(p.join(destination, name));
    if (await file.exists()) {
      throw StateError('Destination already exists: ${file.path}');
    }
    await file.writeAsBytes(ZipEncoder().encode(archive), flush: true);
    return file.path;
  }

  Future<String> exportTask(
    ResearchTask task,
    String destinationDirectory,
  ) async {
    if (store.taskRevision(task.id, task.revision) == null) {
      throw StateError('Unknown task revision');
    }
    final taskData = {
      'format': 'research-task-v1',
      'taskId': task.id,
      'taskRevision': task.revision,
      'projectId': task.projectId,
      'title': task.title,
      'goal': task.goal,
      'spec': task.spec,
    };
    final bytes = utf8.encode(
      const JsonEncoder.withIndent('  ').convert(taskData),
    );
    final manifest = {
      'format': 'research-package-v1',
      'kind': 'task',
      'files': [
        {
          'path': 'task.json',
          'bytes': bytes.length,
          'sha256': sha256.convert(bytes).toString(),
        },
      ],
    };
    final result = {
      'format': 'research-result-v1',
      'runId': const Uuid().v4(),
      'taskId': task.id,
      'taskRevision': task.revision,
      'status': 'completed',
      'metrics': <String, dynamic>{},
      'logs': <String>[],
      'artifacts': <String>[],
    };
    return _zip(
      {
        'task.json': bytes,
        'manifest.json': utf8.encode(jsonEncode(manifest)),
        'result-template.json': utf8.encode(
          const JsonEncoder.withIndent('  ').convert(result),
        ),
        'README.md': utf8.encode(
          '# ${task.title}\n\n${task.goal}\n\nTask ${task.id}, revision ${task.revision}.\n\nThis package is a specification only. No command runs automatically. Code and data references must be acquired and verified separately.\n\nExecute manually in an approved environment, complete result-template.json, and return it (or a ZIP containing result.json and relative artifacts). Status is a reported execution status, not scientific validation.\n',
        ),
      },
      destinationDirectory,
      'task-${task.id}-r${task.revision}-${const Uuid().v4()}.zip',
    );
  }

  Future<ResearchRun> importResult(String jsonOrZipPath) async {
    final snapshot = await _snapshot(jsonOrZipPath, 'results');
    try {
      final files = await snapshot
          .list(recursive: true)
          .where((e) => e is File && p.basename(e.path) == 'result.json')
          .toList();
      File result;
      if (files.length == 1) {
        result = File(files.single.path);
      } else if (!jsonOrZipPath.toLowerCase().endsWith('.zip')) {
        result = File(p.join(snapshot.path, p.basename(jsonOrZipPath)));
      } else {
        throw const FormatException('Result ZIP must contain one result.json');
      }
      final data = WorkbenchStore.decode(await result.readAsString());
      final id = data['runId'],
          taskId = data['taskId'],
          revision = data['taskRevision'],
          status = data['status'];
      if (id is! String ||
          id.isEmpty ||
          taskId is! String ||
          revision is! int ||
          status is! String ||
          status.isEmpty) {
        throw const FormatException(
          'runId, taskId, integer taskRevision and status are required',
        );
      }
      if (store.taskRevision(taskId, revision) == null) {
        throw const FormatException(
          'Result refers to an unknown task revision',
        );
      }
      if (data['metrics'] != null && data['metrics'] is! Map) {
        throw const FormatException('metrics must be an object');
      }
      for (final key in ['logs', 'artifacts']) {
        if (data[key] != null && data[key] is! List) {
          throw FormatException('$key must be a list');
        }
      }
      for (final artifact in (data['artifacts'] as List?) ?? []) {
        final path = artifact is String
            ? artifact
            : (artifact is Map ? artifact['path'] : null);
        if (path is! String) {
          throw const FormatException('Artifacts need relative paths');
        }
        if (!await File(p.join(snapshot.path, _safe(path))).exists()) {
          throw FormatException('Missing artifact: $path');
        }
      }
      final previous = store.db.select('SELECT * FROM runs WHERE id=?', [id]);
      if (previous.isNotEmpty) {
        final old = WorkbenchStore.decode(previous.first['data']);
        old.remove('_snapshotPath');
        if (jsonEncode(old) != jsonEncode(data)) {
          throw const FormatException(
            'Run ID already exists with different contents',
          );
        }
        await snapshot.delete(recursive: true);
        return store.runFromRow(previous.first);
      }
      data['_snapshotPath'] = store.storedPath(snapshot.path);
      store.db.execute('INSERT INTO runs VALUES(?,?,?,?,?,?)', [
        id,
        taskId,
        revision,
        status,
        0,
        jsonEncode(data),
      ]);
      return ResearchRun(
        id: id,
        taskId: taskId,
        status: status,
        taskRevision: revision,
        accepted: false,
        data: data,
      );
    } catch (_) {
      if (await snapshot.exists()) {
        await snapshot.delete(recursive: true);
      }
      rethrow;
    }
  }

  Future<String> exportReport(
    String projectId,
    String destinationDirectory,
  ) async {
    final project = store.projects().firstWhere((e) => e.id == projectId);
    final entries = {
      for (final entry in store.entries(projectId)) entry.id: entry,
    };
    final accepted = {
      for (final run in store.runs(projectId).where((r) => r.accepted))
        run.id: run,
    };
    final out = StringBuffer(
      '# ${project.title}\n\n${project.question}\n\n下一步：${project.nextStep}\n\n',
    );
    for (final item in store.outline(projectId)) {
      out.writeln('## ${item['heading']}\n');
      final evidence = item['evidence_id'];
      if (entries.containsKey(evidence)) {
        final entry = entries[evidence]!;
        out.writeln(
          '${entry.title}\n\n来源记录：$evidence\n\n```json\n${const JsonEncoder.withIndent('  ').convert(entry.data)}\n```\n',
        );
      } else if (accepted.containsKey(evidence)) {
        final run = accepted[evidence]!;
        out.writeln(
          '执行记录：${run.id}，任务 ${run.taskId} r${run.taskRevision}，状态 ${run.status}\n\n指标：${jsonEncode(run.data['metrics'] ?? {})}\n\n产物：${jsonEncode(run.data['artifacts'] ?? [])}\n\n人工关联为证据；此状态不代表科学结论已验证。\n',
        );
      } else {
        out.writeln('待复审或未接纳的证据：$evidence\n');
      }
    }
    out.writeln('## 精读笔记\n');
    for (final doc in store.documents(projectId)) {
      for (final note in store.notes(doc.id)) {
        out.writeln(
          '### ${doc.relativePath} · ${note.locator}\n\n${note.text}\n',
        );
      }
    }
    await Directory(destinationDirectory).create(recursive: true);
    final file = File(
      p.join(destinationDirectory, 'report-$projectId-${const Uuid().v4()}.md'),
    );
    await file.writeAsString(out.toString(), flush: true);
    return file.path;
  }
}
