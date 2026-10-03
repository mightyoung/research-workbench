import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' show Row;
import 'package:uuid/uuid.dart';
import 'models.dart';
import 'research_skill.dart';
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

  /// Files skipped by the last research import (count, bytes).
  (int, int) lastSkipped = (0, 0);

  /// [exclude] receives every candidate name and returns names to skip; the
  /// size limits count only what is kept.
  Future<Directory> _snapshot(
    String input,
    String group, {
    Set<String> Function(List<String> names)? exclude,
  }) async {
    lastSkipped = (0, 0);
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
        final files = <String>[];
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
          if (kind == FileSystemEntityType.file) files.add(item.path);
        }
        final names = [
          for (final f in files)
            p.posix.joinAll(p.split(p.relative(f, from: input))),
        ];
        final skip = exclude?.call(names) ?? const <String>{};
        for (var i = 0; i < files.length; i++) {
          final length = await File(files[i]).length();
          if (skip.contains(names[i])) {
            lastSkipped = (lastSkipped.$1 + 1, lastSkipped.$2 + length);
            continue;
          }
          if (length > maxFileBytes) {
            throw const FormatException('File exceeds 30 MiB');
          }
          await write(names[i], await File(files[i]).readAsBytes());
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
        final skip =
            exclude?.call([
              for (final e in archive)
                if (e.isFile) e.name,
            ]) ??
            const <String>{};
        for (final entry in archive) {
          _safe(entry.name);
          if (entry.isSymbolicLink) {
            throw const FormatException('Symbolic links are not imported');
          }
          if (entry.isFile && skip.contains(entry.name)) {
            lastSkipped = (lastSkipped.$1 + 1, lastSkipped.$2 + entry.size);
          } else if (entry.isFile) {
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
          if (entry.isFile && !skip.contains(entry.name)) {
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

  /// What the last re-import carried over; null after a fresh import.
  ReimportSummary? lastReimport;

  /// Imports a snapshot as a new project, or with [intoProjectId] as the new
  /// current snapshot of that project (design §8). Earlier snapshots stay.
  Future<ResearchProject> importResearch(
    String directoryOrZipPath, {
    String? intoProjectId,
  }) async {
    lastReimport = null;
    final target = intoProjectId == null
        ? null
        : store.db.select(
            'SELECT title,skill_root,current_snapshot FROM projects WHERE id=?',
            [intoProjectId],
          ).firstOrNull;
    if (intoProjectId != null && target == null) {
      throw StateError('Unknown project: $intoProjectId');
    }
    String? root;
    final snapshot = await _snapshot(
      directoryOrZipPath,
      'research',
      exclude: (names) {
        final detected = root = detectSkillRoot(names);
        return detected == null
            ? <String>{}
            : {
                for (final n in names)
                  if (skipSkillPath(n, detected)) n,
              };
      },
    );
    final id = intoProjectId ?? const Uuid().v4();
    final label = p
        .basename(directoryOrZipPath)
        .replaceFirst(RegExp(r'\.zip$', caseSensitive: false), '');
    final title = target?['title'] as String? ?? label;
    final snapshotId = const Uuid().v4();
    store.db.execute('BEGIN');
    try {
      if (target == null) {
        store.db.execute(
          'INSERT INTO projects(id,title,question,next_step) VALUES(?,?,?,?)',
          [id, title, '', ''],
        );
      }
      store.db.execute('INSERT INTO snapshots VALUES(?,?,?,?)', [
        snapshotId,
        id,
        DateTime.now().toUtc().toIso8601String(),
        label,
      ]);
      // research-skill bookkeeping, keyed by project-relative POSIX path.
      final documents = <String, (String, String)>{};
      final manifests = <String, Map<String, dynamic>>{};
      final logs = <ResearchEntry>[];
      var v2 = false;
      await for (final entity in snapshot.list(recursive: true)) {
        if (entity is! File) {
          continue;
        }
        final relative = p.relative(entity.path, from: snapshot.path);
        final posix = p.posix.joinAll(p.split(relative));
        final projectPath = root != null && posix.startsWith(root!)
            ? posix.substring(root!.length)
            : null;
        final ext = p.extension(relative).toLowerCase();
        if (['.md', '.markdown', '.pdf'].contains(ext)) {
          final documentId = const Uuid().v4();
          final hash = sha256.convert(await entity.readAsBytes()).toString();
          store.db.execute(
            'INSERT INTO documents(id,project_id,relative_path,snapshot_path,sha256,snapshot_id) VALUES(?,?,?,?,?,?)',
            [
              documentId,
              id,
              relative,
              store.storedPath(entity.path),
              hash,
              snapshotId,
            ],
          );
          if (projectPath != null) documents[projectPath] = (documentId, hash);
        }
        if (projectPath != null && _isArxivManifest(projectPath)) {
          try {
            manifests[projectPath] = WorkbenchStore.decode(
              await entity.readAsString(),
            );
          } on FormatException {
            // Unreadable manifests simply provide no binding.
          }
        }
        if (ext == '.jsonl') {
          final base = p.basenameWithoutExtension(relative);
          final isLog = projectPath == 'research/$base.jsonl';
          // In research-skill projects only <root>/research/*.jsonl are
          // authoritative logs; same-named copies elsewhere stay 'other'.
          final kind = skillKinds.contains(base) && (root == null || isLog)
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
                        data['observation'] ??
                        data['query'] ??
                        data['step'] ??
                        data['name'] ??
                        data['id'] ??
                        '$base:$line')
                    .toString();
            final entryId = const Uuid().v4();
            // Preserve source IDs verbatim in data; local IDs scope imported snapshots.
            store.db.execute(
              'INSERT INTO entries(id,project_id,kind,title,data,snapshot_id) VALUES(?,?,?,?,?,?)',
              [entryId, id, kind, recordTitle, jsonEncode(data), snapshotId],
            );
            if (isLog && kind != 'other') {
              logs.add(
                ResearchEntry(
                  id: entryId,
                  projectId: id,
                  kind: kind,
                  title: recordTitle,
                  data: data,
                ),
              );
              v2 = v2 || data['schema_version'] == 2;
            }
          }
        }
      }
      final layout = root == null
          ? 'generic'
          : v2
          ? 'research-skill-v2'
          : 'research-skill-v1';
      store.db.execute(
        'UPDATE projects SET layout=?,skill_root=?,current_snapshot=? WHERE id=?',
        [layout, root ?? '', snapshotId, id],
      );
      if (v2) {
        computeBindings(
          entries: logs,
          documents: documents,
          manifests: manifests,
        ).forEach(store.insertBinding);
      }
      final previous = target?['current_snapshot'] as String?;
      if (previous != null) {
        lastReimport = _carryOver(
          id,
          from: previous,
          fromRoot: target!['skill_root'] as String,
          to: snapshotId,
          toRoot: root ?? '',
        );
      }
      store.db.execute('COMMIT');
      return ResearchProject(
        id: id,
        title: title,
        layout: layout,
        skillRoot: root ?? '',
      );
    } catch (_) {
      store.db.execute('ROLLBACK');
      await snapshot.delete(recursive: true);
      rethrow;
    }
  }

  /// Moves notes, outline links and manual binding choices from snapshot
  /// [from] to [to]. Documents match by project-relative path; records by
  /// (kind, id, rev). Nothing is guessed: misses stay on the old snapshot.
  ReimportSummary _carryOver(
    String projectId, {
    required String from,
    required String fromRoot,
    required String to,
    required String toRoot,
  }) {
    final db = store.db;
    String key(Row r, String root) {
      final path = p.posix.joinAll(p.split(r['relative_path'] as String));
      return path.startsWith(root) ? path.substring(root.length) : path;
    }

    final newDocs = {
      for (final r in db.select(
        'SELECT id,relative_path,sha256 FROM documents WHERE snapshot_id=?',
        [to],
      ))
        key(r, toRoot): r,
    };
    var moved = 0, review = 0, left = 0, kept = 0;
    final docMap = <String, String>{};
    for (final old in db.select(
      'SELECT id,relative_path,sha256 FROM documents WHERE snapshot_id=?',
      [from],
    )) {
      final next = newDocs[key(old, fromRoot)];
      if (next != null) docMap[old['id'] as String] = next['id'] as String;
      final count =
          db.select('SELECT COUNT(*) AS c FROM notes WHERE document_id=?', [
                old['id'],
              ]).first['c']
              as int;
      if (count == 0) continue;
      if (next == null) {
        left += count;
        continue;
      }
      final changed = next['sha256'] != old['sha256'];
      db.execute(
        'UPDATE notes SET document_id=?,needs_review=MAX(needs_review,?) WHERE document_id=?',
        [next['id'], changed ? 1 : 0, old['id']],
      );
      moved += count;
      if (changed) review += count;
    }
    String? identity(Row r) {
      final data = WorkbenchStore.decode(r['data'] as String);
      return data['id'] == null || data['rev'] == null
          ? null
          : '${r['kind']}/${data['id']}@${data['rev']}';
    }

    final newEntries = <String, List<String>>{};
    for (final r in db.select(
      'SELECT id,kind,data FROM entries WHERE snapshot_id=?',
      [to],
    )) {
      final k = identity(r);
      if (k != null) newEntries.putIfAbsent(k, () => []).add(r['id'] as String);
    }
    final oldEntries = {
      for (final r in db.select(
        'SELECT id,kind,data FROM entries WHERE snapshot_id=?',
        [from],
      ))
        r['id'] as String: identity(r),
    };
    var outlineMoved = 0, outlineLeft = 0;
    for (final row in store.outline(projectId)) {
      final evidence = row['evidence_id'];
      if (!oldEntries.containsKey(evidence)) continue;
      final matches = newEntries[oldEntries[evidence]];
      if (matches?.length == 1) {
        db.execute('UPDATE outline SET evidence_id=? WHERE id=?', [
          matches!.single,
          row['id'],
        ]);
        outlineMoved++;
      } else {
        outlineLeft++;
      }
    }
    for (final b in db.select(
      "SELECT b.document_id,b.paper_id FROM paper_bindings b JOIN documents d ON d.id=b.document_id WHERE d.snapshot_id=? AND b.method LIKE '%+manual'",
      [from],
    )) {
      final doc = docMap[b['document_id']];
      if (doc == null) continue;
      final candidate = db.select(
        'SELECT 1 FROM paper_bindings WHERE document_id=? AND paper_id=? AND ambiguous=1',
        [doc, b['paper_id']],
      );
      if (candidate.isEmpty) continue;
      store.applyBindingChoice(doc, b['paper_id'] as String);
      kept++;
    }
    return ReimportSummary(
      notesMoved: moved,
      notesNeedReview: review,
      notesLeft: left,
      outlineMoved: outlineMoved,
      outlineLeft: outlineLeft,
      bindingsKept: kept,
    );
  }

  // related_work/<slug>/versions/<vN>/manifest.json written by fetch-paper.sh.
  static bool _isArxivManifest(String path) {
    final parts = path.split('/');
    return parts.length == 5 &&
        parts[0] == 'related_work' &&
        parts[2] == 'versions' &&
        parts[4] == 'manifest.json';
  }

  /// Writes research-skill V2 claim drafts for [noteIds] (design §7). Drafts
  /// are never appended to the project logs by the workbench.
  Future<ClaimDraftExport> exportClaimDrafts(
    String projectId,
    Iterable<String> noteIds,
    String destinationDirectory, {
    DateTime? now,
  }) async {
    final project = store.projects().firstWhere((e) => e.id == projectId);
    if (!project.isSkill) {
      throw StateError('Only research-skill projects support claim drafts');
    }
    final at = now ?? DateTime.now();
    final docs = store.documents(projectId);
    final notes = {
      for (final d in docs)
        for (final n in store.notes(d.id)) n.id: (d, n),
    };
    final bindings = store.bindings(projectId);
    final papers = store.entries(projectId, kind: 'papers');
    final rows = <Map<String, dynamic>>[];
    final skipped = <(String, String)>[];
    final ids = <String>{};
    for (final noteId in noteIds) {
      final found = notes[noteId];
      if (found == null) {
        skipped.add((noteId, '笔记不存在'));
        continue;
      }
      final (doc, note) = found;
      final candidates = bindings.where((b) => b.documentId == doc.id).toList();
      final binding = candidates.where((b) => !b.ambiguous).firstOrNull;
      if (binding == null) {
        skipped.add((
          noteId,
          candidates.isEmpty ? '文档未绑定论文' : '文档有多个候选论文，需先确认绑定',
        ));
        continue;
      }
      final paper = papers
          .where(
            (e) =>
                sourceIdOf(e) == binding.paperId &&
                revOf(e) == binding.paperRev,
          )
          .firstOrNull;
      if (paper == null) {
        skipped.add((noteId, '绑定的论文修订未导入'));
        continue;
      }
      String? text;
      if (!doc.isPdf) {
        try {
          text = stripBom(
            utf8.decode(await File(doc.absolutePath).readAsBytes()),
          );
        } on FormatException {
          text = null;
        }
      }
      String draftId;
      do {
        draftId = 'c-wb-${const Uuid().v4().substring(0, 8)}';
      } while (!ids.add(draftId));
      rows.add(
        claimDraft(
          DraftSource(
            note: note,
            document: doc,
            projectPath: p.posix
                .joinAll(p.split(doc.relativePath))
                .substring(project.skillRoot.length),
            binding: binding,
            paper: paper,
            text: text,
          ),
          id: draftId,
          now: at,
        ),
      );
    }
    if (rows.isEmpty) {
      throw StateError(
        '没有可导出的笔记：${skipped.map((s) => s.$2).toSet().join('；')}',
      );
    }
    await Directory(destinationDirectory).create(recursive: true);
    final stamp = at.toUtc().toIso8601String().replaceAll(
      RegExp(r'[-:]|\.\d+'),
      '',
    );
    final file = File(
      p.join(destinationDirectory, 'workbench-claims-$stamp.jsonl'),
    );
    if (await file.exists()) {
      throw StateError('Destination already exists: ${file.path}');
    }
    await file.writeAsString(encodeJsonl(rows), flush: true);
    return ClaimDraftExport(path: file.path, rows: rows, skipped: skipped);
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
          store.db.execute(
            'INSERT INTO projects(id,title,question,next_step) VALUES(?,?,?,?)',
            [projectId, '接收任务 · $title', goal, '确认环境后由用户手动开始执行记录'],
          );
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
    // Outline links may still point at earlier snapshots after a re-import.
    final entries = {
      for (final entry in store.entries(projectId, allSnapshots: true))
        entry.id: entry,
    };
    final current = {for (final e in store.entries(projectId)) e.id};
    final accepted = {
      for (final run in store.runs(projectId).where((r) => r.accepted))
        run.id: run,
    };
    final noteEvidence = <String, (ResearchDocument, ReadingNote)>{
      for (final doc in store.documents(projectId, allSnapshots: true))
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
        // research-skill refs let check-research.py verify freshness.
        final ref = skillRef(entry);
        out.writeln(
          '${entry.title}\n\n来源记录：${ref == null ? '' : '$ref '}$evidence${current.contains(evidence) ? '' : '（旧快照，最新导入中未找到同一修订）'}\n\n```json\n${const JsonEncoder.withIndent('  ').convert(entry.data)}\n```\n',
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

/// Result of [ResearchExchange.exportClaimDrafts].
class ClaimDraftExport {
  const ClaimDraftExport({
    required this.path,
    required this.rows,
    required this.skipped,
  });
  final String path;
  final List<Map<String, dynamic>> rows;

  /// (note id, reason) for notes that could not become drafts.
  final List<(String, String)> skipped;
  int get notesNeedingReview => rows
      .where((r) => (r['workbench'] as Map)['note_needs_review'] == true)
      .length;
  int get hashMismatches => rows
      .where((r) => (r['workbench'] as Map)['hash_mismatch'] == true)
      .length;
  Set<String> get missingFields => {
    for (final r in rows) ...missingDraftFields(r),
  };
}

/// What [ResearchExchange.importResearch] carried into a new snapshot.
class ReimportSummary {
  const ReimportSummary({
    required this.notesMoved,
    required this.notesNeedReview,
    required this.notesLeft,
    required this.outlineMoved,
    required this.outlineLeft,
    required this.bindingsKept,
  });
  final int notesMoved, notesNeedReview, notesLeft;
  final int outlineMoved, outlineLeft, bindingsKept;
}
