import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'models.dart';
import 'research_kinds.dart';
import 'skill_bridge.dart';
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

  /// Finds whether a local record is cited as evidence (`?1` = local ID).
  static const _citedSql = 'SELECT 1 FROM outline WHERE evidence_id=?1';

  static Future<bool> _sameBytes(String a, String b) async =>
      sha256.convert(await File(a).readAsBytes()) ==
      sha256.convert(await File(b).readAsBytes());

  /// Key-order-independent JSON, for comparing record content.
  static String _canonical(Object? value) => jsonEncode(switch (value) {
    Map m => {
      for (final k in m.keys.map((k) => '$k').toList()..sort())
        k: jsonDecode(_canonical(m[k])),
    },
    List l => [for (final v in l) jsonDecode(_canonical(v))],
    _ => value,
  });

  /// Kinds that older versions imported as `other`.
  static const _newlyRecognised = {
    'sources',
    'searches',
    'tensions',
    'failures',
    'handoffs',
  };

  /// Identifies a source record across re-imports: `id`+`rev` when present,
  /// otherwise the record content.
  static String _entryKey(String kind, Map<String, dynamic> data) =>
      data['id'] != null
      ? '$kind\u0000id:${data['id']}\u0000rev:${data['rev']}'
      : '$kind\u0000sha:${sha256.convert(utf8.encode(jsonEncode(data)))}';

  /// Imports a research snapshot. With [intoProjectId] the snapshot refreshes
  /// that project: records and documents keep their local IDs so notes and
  /// outline links survive; records gone from the source are dropped unless
  /// the outline cites them, documents unless they carry notes.
  Future<ResearchProject> importResearch(
    String directoryOrZipPath, {
    String? intoProjectId,
  }) async {
    final existing = intoProjectId == null
        ? null
        : store.projects().where((p) => p.id == intoProjectId).firstOrNull;
    if (intoProjectId != null && existing == null) {
      throw StateError('Unknown project');
    }
    final snapshot = await _snapshot(directoryOrZipPath, 'research');
    final id = existing?.id ?? const Uuid().v4();
    final title =
        existing?.title ??
        p
            .basename(directoryOrZipPath)
            .replaceFirst(RegExp(r'\.zip$', caseSensitive: false), '');
    final oldEntries = <String, List<String>>{};
    final oldData = <String, Map<String, dynamic>>{};
    for (final e in store.entries(id)) {
      oldEntries.putIfAbsent(_entryKey(e.kind, e.data), () => []).add(e.id);
      oldData[e.id] = e.data;
    }
    // Newest version per path; older versions kept for their notes stay put.
    final oldDocs = {for (final d in store.documents(id)) d.relativePath: d};
    final seen = <String, String>{};
    store.db.execute('BEGIN');
    try {
      final manifest = File(p.join(snapshot.path, 'manifest.json'));
      if (await manifest.exists()) {
        final declared = jsonDecode(await manifest.readAsString());
        if (declared is Map && declared['format'] == 'research-package-v1') {
          throw const FormatException('这是任务包或结果包，请用对应的导入入口');
        }
      }
      if (existing == null) {
        store.db.execute('INSERT INTO projects VALUES(?,?,?,?)', [
          id,
          title,
          '',
          '',
        ]);
      }
      // Refreshing deletes what the source no longer has, so material with
      // nothing recognisable must not reach the cleanup below.
      var found = 0;
      await for (final entity in snapshot.list(recursive: true)) {
        if (entity is! File) {
          continue;
        }
        final relative = p.relative(entity.path, from: snapshot.path);
        final ext = p.extension(relative).toLowerCase();
        if (['.md', '.markdown', '.pdf'].contains(ext)) found++;
        if (['.md', '.markdown', '.pdf'].contains(ext)) {
          final old = oldDocs.remove(relative);
          // Notes cite a page and quote of the bytes they were written on;
          // a changed file with notes becomes a new version beside the old.
          final keepOld =
              old != null &&
              store.db.select('SELECT 1 FROM notes WHERE document_id=?', [
                old.id,
              ]).isNotEmpty &&
              !await _sameBytes(old.absolutePath, entity.path);
          if (old != null && !keepOld) {
            store.db.execute(
              'UPDATE documents SET snapshot_path=? WHERE id=?',
              [store.storedPath(entity.path), old.id],
            );
          } else {
            store.db.execute('INSERT INTO documents VALUES(?,?,?,?)', [
              const Uuid().v4(),
              id,
              relative,
              store.storedPath(entity.path),
            ]);
          }
        }
        if (ext == '.jsonl') {
          final base = p.basenameWithoutExtension(relative);
          final kind = recordKinds.containsKey(base) ? base : 'other';
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
                        data['observation'] ??
                        data['query'] ??
                        data['step'] ??
                        data['cause'] ??
                        data['name'] ??
                        data['id'] ??
                        '$base:$line')
                    .toString();
            // Preserve source IDs verbatim in data; local IDs scope imported snapshots.
            found++;
            final key = _entryKey(kind, data);
            if (seen[key] case final earlier?) {
              if (earlier != _canonical(data)) {
                throw FormatException(
                  '$relative 中 ${data['id']} 修订 ${data['rev']} 出现多次且内容不同',
                );
              }
              continue; // An identical repeated line adds nothing.
            }
            seen[key] = _canonical(data);
            // Older imports stored the newly recognised kinds as `other`;
            // reuse such a row (only when unambiguous) so its local ID and
            // links survive reclassification.
            final legacy = _newlyRecognised.contains(kind)
                ? oldEntries[_entryKey('other', data)]
                : null;
            final reuse = (oldEntries[key]?.isNotEmpty ?? false)
                ? oldEntries[key]
                : (legacy != null && legacy.length == 1 ? legacy : null);
            if (reuse != null) {
              final localId = reuse.removeAt(0);
              // A revision is immutable once cited: silently rewriting it
              // would change evidence the user already linked.
              if (_canonical(oldData[localId]) != _canonical(data) &&
                  store.db.select(_citedSql, [localId]).isNotEmpty) {
                throw FormatException(
                  '$relative 中的 ${data['id']} 修订 ${data['rev']} 内容已改变但修订号未变，'
                  '且已被引用；请在 research-workflow 中新增修订后再导入',
                );
              }
              store.db.execute(
                'UPDATE entries SET kind=?,title=?,data=? WHERE id=?',
                [kind, recordTitle, jsonEncode(data), localId],
              );
            } else {
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
      }
      if (found == 0) {
        throw const FormatException('所选材料中没有 Markdown/PDF 文档或 JSONL 研究记录');
      }
      for (final entryId in oldEntries.values.expand((ids) => ids)) {
        store.db.execute(
          'DELETE FROM entries WHERE id=? AND id NOT IN (SELECT evidence_id FROM outline)',
          [entryId],
        );
      }
      for (final doc in oldDocs.values) {
        store.db.execute(
          'DELETE FROM documents WHERE id=? AND id NOT IN (SELECT document_id FROM notes)',
          [doc.id],
        );
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

  Future<Set<String>> _verifyManifest(Directory snapshot, String kind) async {
    final file = File(p.join(snapshot.path, 'manifest.json'));
    if (!await file.exists()) {
      throw const FormatException('Missing manifest.json');
    }
    final manifest = WorkbenchStore.decode(await file.readAsString());
    if (manifest['format'] != 'research-package-v1' ||
        manifest['kind'] != kind ||
        manifest['files'] is! List) {
      throw const FormatException('Unsupported package manifest');
    }
    final listed = <String>{};
    for (final item in manifest['files'] as List) {
      if (item is! Map ||
          item['path'] is! String ||
          item['bytes'] is! int ||
          item['sha256'] is! String) {
        throw const FormatException('Invalid manifest file entry');
      }
      final safe = _safe(item['path'] as String);
      if (!listed.add(safe)) {
        throw FormatException('Duplicate manifest path: $safe');
      }
      final member = File(p.join(snapshot.path, safe));
      if (!await member.exists() || await member.length() != item['bytes']) {
        throw FormatException(
          'Missing or changed package file: ${item['path']}',
        );
      }
      final digest = await sha256.bind(member.openRead()).first;
      if (digest.toString() != item['sha256']) {
        throw FormatException('Package checksum mismatch: ${item['path']}');
      }
    }
    final required = kind == 'task' ? 'task.json' : 'result.json';
    if (!listed.contains(required)) {
      throw FormatException('Package manifest must verify $required');
    }
    return listed;
  }

  /// Import a task specification without running its command or opening its data.
  Future<ResearchTask> importTask(String zipPath) async {
    if (!zipPath.toLowerCase().endsWith('.zip')) {
      throw const FormatException('Task package must be ZIP');
    }
    final snapshot = await _snapshot(zipPath, 'tasks');
    try {
      await _verifyManifest(snapshot, 'task');
      final taskFile = File(p.join(snapshot.path, 'task.json'));
      if (!await taskFile.exists()) {
        throw const FormatException('Missing task.json');
      }
      final data = WorkbenchStore.decode(await taskFile.readAsString());
      final id = data['taskId'], revision = data['taskRevision'];
      final projectId = data['projectId'], title = data['title'];
      final goal = data['goal'], spec = data['spec'];
      if (data['format'] != 'research-task-v1' ||
          id is! String ||
          id.isEmpty ||
          revision is! int ||
          revision < 1 ||
          projectId is! String ||
          projectId.isEmpty ||
          title is! String ||
          title.trim().isEmpty ||
          goal is! String ||
          spec is! Map<String, dynamic>) {
        throw const FormatException('Invalid task specification');
      }
      final existing = store.taskRevision(id, revision);
      if (existing != null) {
        if (existing.projectId != projectId ||
            existing.title != title ||
            existing.goal != goal ||
            jsonEncode(existing.spec) != jsonEncode(spec)) {
          throw const FormatException(
            'Task revision conflicts with local data',
          );
        }
        await snapshot.delete(recursive: true);
        return existing;
      }
      final digest = await sha256.bind(File(zipPath).openRead()).first;
      store.db.execute('BEGIN');
      try {
        if (store.db.select('SELECT id FROM projects WHERE id=?', [
          projectId,
        ]).isEmpty) {
          store.db.execute('INSERT INTO projects VALUES(?,?,?,?)', [
            projectId,
            '接收任务 · $title',
            goal,
            '确认环境后由用户手动开始执行记录',
          ]);
        }
        store.db.execute('INSERT INTO tasks VALUES(?,?,?,?,?,?)', [
          id,
          revision,
          projectId,
          title,
          goal,
          jsonEncode(spec),
        ]);
        store.db.execute('INSERT INTO task_imports VALUES(?,?,?,?)', [
          id,
          revision,
          store.storedPath(snapshot.path),
          digest.toString(),
        ]);
        store.db.execute('COMMIT');
      } catch (_) {
        store.db.execute('ROLLBACK');
        rethrow;
      }
      return store.taskRevision(id, revision)!;
    } catch (_) {
      if (await snapshot.exists()) await snapshot.delete(recursive: true);
      rethrow;
    }
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
      'finishedAt': '',
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
          '# ${task.title}\n\n${task.goal}\n\nTask ${task.id}, revision ${task.revision}.\n\nThis package is a specification only. No command runs automatically. Code and data references must be acquired and verified separately.\n\nExecute manually in an approved environment, complete result-template.json (set finishedAt to the ISO-8601 UTC time the run ended), and return it (or a ZIP containing result.json and relative artifacts). Status is a reported execution status, not scientific validation.\n',
        ),
      },
      destinationDirectory,
      'task-${task.id}-r${task.revision}-${const Uuid().v4()}.zip',
    );
  }

  /// Package a user-recorded run and explicitly chosen artifacts for return.
  Future<String> exportResult(
    ResearchRun run,
    String destinationDirectory, {
    List<String> artifactPaths = const [],
  }) async {
    final rows = store.db.select('SELECT * FROM runs WHERE id=?', [run.id]);
    if (rows.isEmpty) throw StateError('Unknown run');
    final current = store.runFromRow(rows.single);
    if (current.data['_localManual'] != true ||
        store.taskRevision(current.taskId, current.taskRevision) == null) {
      throw StateError('Only a recorded local task run can be exported');
    }
    final files = <String, List<int>>{};
    final artifacts = <Map<String, dynamic>>[];
    var total = 0;
    for (var i = 0; i < artifactPaths.length; i++) {
      final source = File(artifactPaths[i]);
      if (await FileSystemEntity.type(source.path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw const FormatException('Artifact must be a regular file');
      }
      final length = await source.length();
      if (length > maxFileBytes || (total += length) > maxBytes) {
        throw const FormatException('Artifacts exceed package size limit');
      }
      final name = _safe('artifacts/${i + 1}-${p.basename(source.path)}');
      files[name] = await source.readAsBytes();
      artifacts.add({'path': name, 'name': p.basename(source.path)});
    }
    final result = <String, dynamic>{
      'format': 'research-result-v1',
      'runId': current.id,
      'taskId': current.taskId,
      'taskRevision': current.taskRevision,
      'status': current.status,
      'metrics': current.data['metrics'] ?? <String, dynamic>{},
      'logs': current.data['logs'] ?? <String>[],
      'conclusion': current.data['conclusion'] ?? '',
      if (current.data['finishedAt'] != null)
        'finishedAt': current.data['finishedAt'],
      'artifacts': artifacts,
    };
    files['result.json'] = utf8.encode(
      const JsonEncoder.withIndent('  ').convert(result),
    );
    files['manifest.json'] = utf8.encode(
      jsonEncode({
        'format': 'research-package-v1',
        'kind': 'result',
        'files': [
          for (final entry in files.entries)
            {
              'path': entry.key,
              'bytes': entry.value.length,
              'sha256': sha256.convert(entry.value).toString(),
            },
        ],
      }),
    );
    return _zip(
      files,
      destinationDirectory,
      'result-${current.id}-${const Uuid().v4()}.zip',
    );
  }

  /// Writes an assessed run as one research-workflow `experiments` JSONL
  /// line, to append to the skill project's `research/experiments.jsonl`.
  Future<String> exportSkillExperiment(
    ResearchRun run,
    String destinationDirectory,
  ) async {
    final task = store.taskRevision(run.taskId, run.taskRevision);
    if (task == null) throw StateError('Unknown task revision');
    final record = executedExperiment(
      task: task,
      run: run,
      now: DateTime.now(),
    );
    await Directory(destinationDirectory).create(recursive: true);
    final file = File(
      p.join(destinationDirectory, 'experiments-${record['id']}.jsonl'),
    );
    await file.writeAsString('${jsonEncode(record)}\n', flush: true);
    return file.path;
  }

  Future<ResearchRun> importResult(String jsonOrZipPath) async {
    final snapshot = await _snapshot(jsonOrZipPath, 'results');
    try {
      final verifiedPaths = jsonOrZipPath.toLowerCase().endsWith('.zip')
          ? await _verifyManifest(snapshot, 'result')
          : <String>{};
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
        final safe = _safe(path);
        if (verifiedPaths.isNotEmpty && !verifiedPaths.contains(safe)) {
          throw FormatException('Unverified artifact: $path');
        }
        if (!await File(p.join(snapshot.path, safe)).exists()) {
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
    final noteEvidence = <String, (ResearchDocument, ReadingNote)>{
      for (final doc in store.documents(projectId))
        for (final note in store.notes(doc.id)) note.id: (doc, note),
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
      } else if (noteEvidence.containsKey(evidence)) {
        final (doc, note) = noteEvidence[evidence]!;
        out.writeln(
          '精读证据：${note.id}\n\n来源：${doc.relativePath}'
          '${note.pageNumber == null ? '' : ' · p. ${note.pageNumber}'}'
          '${note.locator.isEmpty ? '' : ' · ${note.locator}'}\n\n'
          '${note.quote.isEmpty ? '' : '> ${note.quote}\n\n'}'
          '${note.text}\n',
        );
      } else {
        out.writeln('待复审或未接纳的证据：$evidence\n');
      }
    }
    out.writeln('## 精读笔记\n');
    for (final doc in store.documents(projectId)) {
      for (final note in store.notes(doc.id)) {
        out.writeln(
          '### ${doc.relativePath} · ${note.locator}'
          '${note.pageNumber == null ? '' : ' · p. ${note.pageNumber}'}\n\n'
          '${note.quote.isEmpty ? '' : '> ${note.quote}\n\n'}'
          '${note.text}\n',
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
