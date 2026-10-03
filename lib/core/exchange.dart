import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'models.dart';
import 'research_skill.dart';
import 'result_payload.dart';
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

  /// SQL conditions, over an `entries` row aliased `e`, under which a record
  /// is cited and must neither change under the same revision nor be dropped.
  static const _citedBy = [
    'e.id IN (SELECT evidence_id FROM outline)',
    'e.id IN (SELECT entry_id FROM notes WHERE entry_id IS NOT NULL)',
    // A plan a generated task was built from (see taskFromExperiment).
    "e.kind='experiments' AND EXISTS (SELECT 1 FROM tasks t "
        'WHERE t.project_id=e.project_id '
        "AND json_extract(t.spec,'\$.source.kind')='experiments' "
        "AND json_extract(t.spec,'\$.source.id')=json_extract(e.data,'\$.id') "
        "AND json_extract(t.spec,'\$.source.rev')=json_extract(e.data,'\$.rev'))",
  ];
  static final _cited = _citedBy.map((c) => '($c)').join(' OR ');
  static final _citedSql = 'SELECT 1 FROM entries e WHERE e.id=? AND ($_cited)';

  /// Run data the workbench adds on top of an imported result payload.
  static const _localRunKeys = {
    '_snapshotPath',
    'workbench_assessment',
    '_skill_export',
  };

  /// Exchange fields only. Local annotations stay in the store.
  Map<String, dynamic> _publicRun(Map<String, dynamic> value) => publicResult(
    Map<String, dynamic>.from(value)
      ..removeWhere((key, _) => _localRunKeys.contains(key)),
  );

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

  /// Kinds that versions before research-skill support imported as `other`.
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
      : '$kind\u0000sha:${sha256.convert(utf8.encode(_canonical(data)))}';

  /// Imports a research snapshot. With [intoProjectId] the snapshot refreshes
  /// that project: records and documents keep their local IDs so notes and
  /// outline links survive; records gone from the source are dropped unless
  /// cited (outline, note or generated task), documents unless they carry
  /// notes. Paper bindings are recomputed on the new snapshot.
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
    // Newest version per project-relative path (a ZIP's top-level folder is
    // not part of it); older versions kept for their notes stay put.
    final oldDocs = {
      for (final d in store.documents(id))
        _docKey(d.relativePath, existing?.skillRoot ?? ''): d,
    };
    // Manual binding choices survive a refresh when the same ambiguity recurs.
    final manual = <String, List<String>>{};
    for (final b in store.bindings(id)) {
      if (b.method.endsWith('+manual')) {
        manual.putIfAbsent(b.documentId, () => []).add(b.paperId);
      }
    }
    final carry = <String, List<String>>{};
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
        store.db.execute(
          'INSERT INTO projects(id,title,question,next_step) VALUES(?,?,?,?)',
          [id, title, '', ''],
        );
      }
      // research-skill bookkeeping, keyed by project-relative POSIX path.
      final documents = <String, (String, String)>{};
      final manifests = <String, Map<String, dynamic>>{};
      final logs = <ResearchEntry>[];
      var v2 = false;
      // Refreshing deletes what the source no longer has, so material with
      // nothing recognisable must not reach the cleanup below.
      var found = 0;
      // Source key -> location, to report cited revisions whose content changed.
      final incomingKeys = <String, String>{};
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
          found++;
          final hash = sha256.convert(await entity.readAsBytes()).toString();
          final old = oldDocs.remove(_docKey(relative, root ?? ''));
          // Notes cite a page and quote of the bytes they were written on;
          // a changed file with notes becomes a new version beside the old.
          final keepOld =
              old != null &&
              store.db.select('SELECT 1 FROM notes WHERE document_id=?', [
                old.id,
              ]).isNotEmpty &&
              old.sha256 != hash &&
              !await _sameBytes(old.absolutePath, entity.path);
          final String documentId;
          if (old != null && !keepOld) {
            documentId = old.id;
            // Its bindings are recomputed below; retained versions keep theirs.
            store.db.execute('DELETE FROM paper_bindings WHERE document_id=?', [
              documentId,
            ]);
            store.db.execute(
              'UPDATE documents SET relative_path=?,snapshot_path=?,sha256=? WHERE id=?',
              [relative, store.storedPath(entity.path), hash, documentId],
            );
          } else {
            documentId = const Uuid().v4();
            store.db.execute(
              'INSERT INTO documents(id,project_id,relative_path,snapshot_path,sha256) VALUES(?,?,?,?,?)',
              [documentId, id, relative, store.storedPath(entity.path), hash],
            );
          }
          if (old != null && manual[old.id] != null) {
            carry[documentId] = manual[old.id]!;
          }
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
            stripBom(await entity.readAsString()),
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
            found++;
            // Duplicate id+rev rows are all kept and flagged by the revision
            // view (design §4); each pairs with at most one earlier row.
            final key = _entryKey(kind, data);
            // Older imports stored the newly recognised kinds as `other`;
            // reuse such a row (only when unambiguous) so its local ID and
            // links survive reclassification.
            final legacy = _newlyRecognised.contains(kind)
                ? oldEntries[_entryKey('other', data)]
                : null;
            final reuse = (oldEntries[key]?.isNotEmpty ?? false)
                ? oldEntries[key]
                : (legacy != null && legacy.length == 1 ? legacy : null);
            incomingKeys[key] = '$relative 中的 ${data['id']} 修订 ${data['rev']}';
            // Pair with an old row of identical content, else with an uncited
            // one: cited revisions are immutable and never rewritten here.
            // Among identical rows the cited one wins, so a leftover cited
            // duplicate is never mistaken for changed content.
            bool same(String old) =>
                _canonical(oldData[old]) == _canonical(data);
            bool cited(String old) =>
                store.db.select(_citedSql, [old]).isNotEmpty;
            var pick = reuse?.indexWhere((old) => same(old) && cited(old));
            if (reuse != null && pick! < 0) pick = reuse.indexWhere(same);
            if (reuse != null && pick! < 0) {
              pick = reuse.indexWhere((old) => !cited(old));
            }
            final String entryId;
            if (reuse != null && pick! >= 0) {
              entryId = reuse.removeAt(pick);
              store.db.execute(
                'UPDATE entries SET kind=?,title=?,data=? WHERE id=?',
                [kind, recordTitle, jsonEncode(data), entryId],
              );
            } else {
              entryId = const Uuid().v4();
              store.db.execute('INSERT INTO entries VALUES(?,?,?,?,?)', [
                entryId,
                id,
                kind,
                recordTitle,
                jsonEncode(data),
              ]);
            }
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
      if (found == 0) {
        throw const FormatException('所选材料中没有 Markdown/PDF 文档或 JSONL 研究记录');
      }
      for (final MapEntry(key: key, value: ids) in oldEntries.entries) {
        for (final entryId in ids) {
          if (store.db.select(_citedSql, [entryId]).isEmpty) {
            store.db.execute('DELETE FROM entries WHERE id=?', [entryId]);
          } else if (incomingKeys[key] case final where?) {
            // The source still has this id+rev, but not the cited content.
            throw FormatException(
              '$where 内容已改变但修订号未变，且已被引用；请在 research-workflow 中新增修订后再导入',
            );
          }
        }
      }
      for (final doc in oldDocs.values) {
        const unnoted = 'NOT IN (SELECT document_id FROM notes)';
        store.db.execute(
          'DELETE FROM paper_bindings WHERE document_id=? AND document_id $unnoted',
          [doc.id],
        );
        store.db.execute('DELETE FROM documents WHERE id=? AND id $unnoted', [
          doc.id,
        ]);
      }
      var layout = 'generic';
      if (root != null) {
        layout = v2 ? 'research-skill-v2' : 'research-skill-v1';
        if (v2) {
          computeBindings(
            entries: logs,
            documents: documents,
            manifests: manifests,
          ).forEach(store.insertBinding);
          for (final MapEntry(key: doc, value: papers) in carry.entries) {
            for (final paper in papers) {
              final pending = store.db.select(
                'SELECT 1 FROM paper_bindings WHERE document_id=? AND paper_id=? AND ambiguous=1',
                [doc, paper],
              );
              if (pending.isNotEmpty) store.applyBindingChoice(doc, paper);
            }
          }
        }
      }
      store.db.execute('UPDATE projects SET layout=?,skill_root=? WHERE id=?', [
        layout,
        root ?? '',
        id,
      ]);
      store.db.execute('COMMIT');
      return ResearchProject(
        id: id,
        title: title,
        question: existing?.question ?? '',
        nextStep: existing?.nextStep ?? '',
        layout: layout,
        skillRoot: root ?? '',
      );
    } catch (_) {
      store.db.execute('ROLLBACK');
      await snapshot.delete(recursive: true);
      rethrow;
    }
  }

  /// Document identity across refreshes: POSIX path below the skill root.
  static String _docKey(String relativePath, String root) {
    final path = p.posix.joinAll(p.split(relativePath));
    return path.startsWith(root) ? path.substring(root.length) : path;
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
        current.data.containsKey('_snapshotPath') ||
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
    final result = _publicRun(current.data)..['artifacts'] = artifacts;
    final hashes = {
      for (final entry in files.entries)
        entry.key: sha256.convert(entry.value).toString(),
    };
    final digest = _resultDigest(result, hashes);
    final previousDigest = current.data['_exportedDigest'];
    if (previousDigest != null && previousDigest != digest) {
      throw StateError('Result changed after export; create a new run/attempt');
    }
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
    final path = await _zip(
      files,
      destinationDirectory,
      'result-${current.id}-${const Uuid().v4()}.zip',
    );
    store.recordResultExport(current.id, digest);
    return path;
  }

  String _resultDigest(Map<String, dynamic> data, Map<String, String> hashes) =>
      sha256
          .convert(
            utf8.encode(
              jsonEncode(
                publicResult({
                  'result': publicResult(data),
                  'artifactHashes': hashes,
                }),
              ),
            ),
          )
          .toString();

  Future<Map<String, String>> _snapshotHashes(
    Directory snapshot,
    Set<String> verifiedPaths,
  ) async => {
    for (final path in verifiedPaths.where((path) => path != 'result.json'))
      path:
          (await sha256
                  .bind(File(p.join(snapshot.path, path)).openRead())
                  .first)
              .toString(),
  };

  /// Writes an assessed run as one research-workflow `experiments` JSONL
  /// line, to append to the skill project's `research/experiments.jsonl`.
  Future<String> exportSkillExperiment(
    ResearchRun run,
    String destinationDirectory,
  ) async {
    final task = store.taskRevision(run.taskId, run.taskRevision);
    if (task == null) throw StateError('Unknown task revision');
    // Same content keeps its revision; a corrected export appends a new one,
    // since the skill treats each id+rev as immutable.
    final now = DateTime.now();
    String digest(Map<String, dynamic> r) => sha256
        .convert(utf8.encode(_canonical({...r}..remove('updated_at'))))
        .toString();
    final previous = run.data['_skill_export'];
    final prevRev = previous is Map && previous['rev'] is int
        ? previous['rev'] as int
        : 0;
    final unchanged = executedExperiment(
      task: task,
      run: run,
      now: now,
      rev: prevRev,
    );
    final sameAsBefore =
        previous is Map && previous['sha256'] == digest(unchanged);
    final record = sameAsBefore
        ? unchanged
        : executedExperiment(task: task, run: run, now: now, rev: prevRev + 1);
    store.db.execute('UPDATE runs SET data=? WHERE id=?', [
      jsonEncode({
        ...run.data,
        '_skill_export': {'rev': record['rev'], 'sha256': digest(record)},
      }),
      run.id,
    ]);
    await Directory(destinationDirectory).create(recursive: true);
    final file = File(
      p.join(destinationDirectory, 'experiments-${record['id']}.jsonl'),
    );
    await file.writeAsString('${jsonEncode(record)}\n', flush: true);
    return file.path;
  }

  Future<ResearchRun> importResult(String jsonOrZipPath) async {
    final snapshot = await _snapshot(jsonOrZipPath, 'results');
    var retainConflict = false;
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
      // Local bookkeeping is never a package-controlled business field.
      final data = _publicRun(
        WorkbenchStore.decode(await result.readAsString()),
      );
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
        final hashes = await _snapshotHashes(snapshot, verifiedPaths);
        final receipt = old['_exportedDigest'];
        final stored = _publicRun(old);
        var same = samePublicResult(stored, data);
        if (old['_localManual'] == true &&
            !old.containsKey('_snapshotPath') &&
            receipt is String) {
          // Artifacts chosen at export live in the immutable receipt, not the
          // editable manual record. All other current public fields must match.
          same =
              samePublicResult({
                ...stored,
                'artifacts': data['artifacts'],
              }, data) &&
              receipt == _resultDigest(data, hashes);
        } else if (same) {
          final storedSnapshot = old['_snapshotPath'];
          final oldHashes = <String, String>{};
          if (storedSnapshot is String) {
            final directory = Directory(store.resolvePath(storedSnapshot));
            if (await File(p.join(directory.path, 'manifest.json')).exists()) {
              oldHashes.addAll(
                await _snapshotHashes(
                  directory,
                  await _verifyManifest(directory, 'result'),
                ),
              );
            }
          }
          same =
              _resultDigest(stored, oldHashes) == _resultDigest(data, hashes);
        }
        if (!same) {
          retainConflict = true;
          throw FormatException(
            'Run ID already exists with different contents; retained snapshot: '
            '${snapshot.path}',
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
      if (!retainConflict && await snapshot.exists()) {
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
    String about(ReadingNote note) => note.entryId == null
        ? ''
        : '关联研究对象：${entries[note.entryId]?.title ?? note.entryId}\n\n';
    String evidence(String id) {
      if (entries[id] case final entry?) {
        // research-skill refs let check-research.py verify freshness.
        final ref = skillRef(entry);
        return '${entry.title}\n\n来源记录：${ref == null ? '' : '$ref '}$id\n\n```json\n${const JsonEncoder.withIndent('  ').convert(entry.data)}\n```\n';
      }
      if (accepted[id] case final run?) {
        return '执行记录：${run.id}，任务 ${run.taskId} r${run.taskRevision}，状态 ${run.status}\n\n指标：${jsonEncode(run.data['metrics'] ?? {})}\n\n产物：${jsonEncode(run.data['artifacts'] ?? [])}\n\n人工关联为证据；此状态不代表科学结论已验证。\n';
      }
      if (noteEvidence[id] case (final doc, final note)) {
        return '精读证据：${note.id}\n\n来源：${doc.relativePath}'
            '${note.pageNumber == null ? '' : ' · p. ${note.pageNumber}'}'
            '${note.locator.isEmpty ? '' : ' · ${note.locator}'}\n\n'
            '${note.quote.isEmpty ? '' : '> ${note.quote}\n\n'}'
            '${about(note)}${note.text}\n';
      }
      return '待复审或未接纳的证据：$id\n';
    }

    final links = store.outline(projectId);
    for (final section in store.sections(projectId)) {
      out.writeln('${'#' * (section.level + 1)} ${section.heading}\n');
      if (section.argument.isNotEmpty) out.writeln('${section.argument}\n');
      out.writeln('证据支持程度：${sectionSupport[section.support]}\n');
      final cited = links.where((l) => l['section_id'] == section.id).toList();
      for (final (i, link) in cited.indexed) {
        out.writeln('**证据 ${i + 1}**\n\n${evidence('${link['evidence_id']}')}');
      }
    }
    out.writeln('## 精读笔记\n');
    for (final doc in store.documents(projectId)) {
      for (final note in store.notes(doc.id)) {
        out.writeln(
          '### ${doc.relativePath} · ${note.locator}'
          '${note.pageNumber == null ? '' : ' · p. ${note.pageNumber}'}\n\n'
          '${note.quote.isEmpty ? '' : '> ${note.quote}\n\n'}'
          '${about(note)}${note.text}\n',
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
  int get hashMismatches => rows
      .where((r) => (r['workbench'] as Map)['hash_mismatch'] == true)
      .length;
  Set<String> get missingFields => {
    for (final r in rows) ...missingDraftFields(r),
  };
}
