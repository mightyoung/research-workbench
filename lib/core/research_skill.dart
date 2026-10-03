import 'dart:convert';

import 'package:path/path.dart' as p;

import 'models.dart';

/// research-skill v6.5 project layout support. research-skill is the format
/// authority: this file only reads its V2 logs and drafts rows in its format.
/// See docs/research-skill-integration.md.
const skillKinds = [
  'sources',
  'papers',
  'claims',
  'opportunities',
  'searches',
  'tensions',
  'experiments',
  'failures',
  'handoffs',
];
const _baseLogs = ['papers', 'claims', 'sources', 'opportunities'];
const evidenceKinds = ['paper_statement', 'inference', 'hypothesis'];

/// Returns the project-root prefix ('' or 'dir/') when [names] contain all
/// four base logs under one `research/` folder; null for generic material.
String? detectSkillRoot(Iterable<String> names) {
  final set = names.map((n) => n.replaceAll('\\', '/')).toSet();
  String? best;
  for (final name in set) {
    if (!name.endsWith('research/papers.jsonl')) continue;
    final prefix = name.substring(
      0,
      name.length - 'research/papers.jsonl'.length,
    );
    if (prefix.isNotEmpty && !prefix.endsWith('/')) continue;
    if (_baseLogs.every(
          (log) => set.contains('${prefix}research/$log.jsonl'),
        ) &&
        (best == null || prefix.length < best.length)) {
      best = prefix;
    }
  }
  return best;
}

/// Bulky or non-reading content in a research-skill project (mirrors the
/// `.gitignore` written by init_project.py, but keeps related_work papers).
bool skipSkillPath(String name, String root) {
  final normalized = name.replaceAll('\\', '/');
  if (!normalized.startsWith(root)) return false;
  final parts = normalized.substring(root.length).split('/');
  if (parts.any((s) => s == '__pycache__' || s == '.shot-tmp' || s == '.git')) {
    return true;
  }
  if (parts.first == 'DataSet') return true;
  if (parts.first == 'experiment' && parts.contains('checkpoints')) return true;
  if (p.posix.extension(normalized).toLowerCase() == '.pt') return true;
  if (parts.first == 'related_work') {
    if (parts.last == '.fetch.lock' ||
        parts.any((s) => s.startsWith('.stage-'))) {
      return true;
    }
    // related_work/<slug>/versions/<vN>/source/** holds TeX archives.
    if (parts.length > 5 && parts[2] == 'versions' && parts[4] == 'source') {
      return true;
    }
  }
  return false;
}

String? sourceIdOf(ResearchEntry e) => e.data['id']?.toString();
int? revOf(ResearchEntry e) {
  final rev = e.data['rev'];
  return rev is int ? rev : int.tryParse('${rev ?? ''}');
}

/// One record identity (kind + id) with its append-only history.
class RevisionGroup {
  RevisionGroup(this.history);

  /// Import order; the current row is the last row with the highest rev.
  final List<ResearchEntry> history;
  ResearchEntry get current {
    final top = history
        .map((e) => revOf(e) ?? 0)
        .reduce((a, b) => a > b ? a : b);
    return history.lastWhere((e) => (revOf(e) ?? 0) == top);
  }

  bool get duplicate {
    final rev = revOf(current) ?? 0;
    return history.where((e) => (revOf(e) ?? 0) == rev).length > 1;
  }

  bool get retired => current.data['active'] == false;
  bool get needsReview => current.kind == 'opportunities'
      ? current.data['status'] == 'needs_review'
      : current.data['review_status'] == 'needs_review';
  List<ResearchEntry> get older => history.where((e) => e != current).toList();
}

/// Groups append-only rows by (kind, id). Rows without an id stay single.
List<RevisionGroup> revisionGroups(List<ResearchEntry> entries) {
  final groups = <String, List<ResearchEntry>>{};
  for (final e in entries) {
    final id = sourceIdOf(e);
    groups
        .putIfAbsent(
          id == null ? 'local:${e.id}' : '${e.kind}\u0000$id',
          () => [],
        )
        .add(e);
  }
  return groups.values.map(RevisionGroup.new).toList();
}

/// Highest imported rev per (kind, id), for "newer revision exists" badges.
Map<String, int> latestRevisions(List<ResearchEntry> entries) {
  final latest = <String, int>{};
  for (final e in entries) {
    final id = sourceIdOf(e), rev = revOf(e);
    if (id == null || rev == null) continue;
    final key = '${e.kind}/$id';
    if (rev > (latest[key] ?? 0)) latest[key] = rev;
  }
  return latest;
}

/// A candidate link between an imported document and a paper record.
class BindingCandidate {
  const BindingCandidate(
    this.documentId,
    this.paperId,
    this.paperRev,
    this.method,
    this.hashOk,
  );
  final String documentId, paperId, method;
  final int paperRev;
  final bool hashOk;
}

/// Computes paper↔document bindings for the current paper revisions.
/// [documents] maps project-relative path → (document id, sha256);
/// [manifests] maps project-relative arXiv manifest path → decoded JSON.
List<PaperBinding> computeBindings({
  required List<ResearchEntry> entries,
  required Map<String, (String, String)> documents,
  required Map<String, Map<String, dynamic>> manifests,
}) {
  final sources = <String, Map<String, dynamic>>{
    for (final e in entries.where((e) => e.kind == 'sources'))
      '${sourceIdOf(e)}@${revOf(e)}': e.data,
  };
  final papers =
      revisionGroups(entries.where((e) => e.kind == 'papers').toList())
          .where(
            (g) =>
                !g.retired &&
                sourceIdOf(g.current) != null &&
                revOf(g.current) != null,
          )
          .map((g) => g.current);
  final candidates = <BindingCandidate>[];
  for (final paper in papers) {
    final d = paper.data, id = sourceIdOf(paper)!, rev = revOf(paper)!;
    final found = <BindingCandidate>[];
    final binding =
        sources['${d['source_id']}@${d['source_rev']}']?['material_binding'];
    if (binding is Map && binding['path'] is String) {
      final doc = documents[binding['path']];
      if (doc != null) {
        found.add(
          BindingCandidate(
            doc.$1,
            id,
            rev,
            'material_binding',
            doc.$2 == binding['sha256'],
          ),
        );
      }
    }
    final arxiv = d['arxiv_id'], version = d['version'];
    if (found.isEmpty && arxiv is String && version is String) {
      for (final MapEntry(key: path, value: manifest) in manifests.entries) {
        if (manifest['arxiv_id'] != '$arxiv$version') continue;
        final pdf = p.posix.join(p.posix.dirname(path), 'paper.pdf');
        final doc = documents[pdf];
        if (doc == null) continue;
        final hashes = manifest['sha256'];
        found.add(
          BindingCandidate(
            doc.$1,
            id,
            rev,
            'arxiv_manifest',
            hashes is Map && hashes['paper.pdf'] == doc.$2,
          ),
        );
      }
    }
    candidates.addAll(found);
  }
  int count(bool Function(BindingCandidate) test) =>
      candidates.where(test).length;
  return [
    for (final c in candidates)
      PaperBinding(
        documentId: c.documentId,
        paperId: c.paperId,
        paperRev: c.paperRev,
        method: c.method,
        hashOk: c.hashOk,
        ambiguous:
            count((o) => o.documentId == c.documentId) > 1 ||
            count((o) => o.paperId == c.paperId) > 1,
      ),
  ];
}

final _skillRef = RegExp(
  r'\[(' + skillKinds.join('|') + r')/([^\]\s@/]+)@(\d+)\](?!\()',
);
const refScheme = 'wbref';

/// Turns `[kind/id@rev]` deliverable references into tappable links, leaving
/// fenced blocks and inline code untouched.
String linkSkillRefs(String markdown) {
  // Open fence marker (``` or ~~~); a fence closes only with its own marker.
  String? fence;
  return markdown
      .split('\n')
      .map((line) {
        final trimmed = line.trimLeft();
        final marker = trimmed.startsWith('```')
            ? '```'
            : trimmed.startsWith('~~~')
            ? '~~~'
            : null;
        if (marker != null && (fence == null || fence == marker)) {
          fence = fence == null ? marker : null;
          return line;
        }
        if (fence != null) return line;
        final parts = line.split('`');
        for (var i = 0; i < parts.length; i += 2) {
          parts[i] = parts[i].replaceAllMapped(
            _skillRef,
            (m) =>
                '${m[0]}($refScheme:${m[1]}/${Uri.encodeComponent(m[2]!)}@${m[3]})',
          );
        }
        return parts.join('`');
      })
      .join('\n');
}

/// Parses a `wbref:kind/id@rev` link into its parts.
(String, String, int)? parseSkillRef(String href) {
  final m = RegExp('^$refScheme:([a-z]+)/([^@]+)@(\\d+)\$').firstMatch(href);
  if (m == null || !skillKinds.contains(m[1])) return null;
  return (m[1]!, Uri.decodeComponent(m[2]!), int.parse(m[3]!));
}

/// Report reference in research-skill deliverable syntax, or null.
String? skillRef(ResearchEntry e) {
  final id = sourceIdOf(e), rev = revOf(e);
  if (!skillKinds.contains(e.kind) || id == null || rev == null) return null;
  return '[${e.kind}/$id@$rev]';
}

/// Input for one draft claim row.
class DraftSource {
  const DraftSource({
    required this.note,
    required this.document,
    required this.projectPath,
    required this.binding,
    required this.paper,
    required this.text,
  });
  final ReadingNote note;
  final ResearchDocument document;

  /// Path relative to the research-skill project root.
  final String projectPath;
  final PaperBinding binding;
  final ResearchEntry paper;

  /// Decoded UTF-8 text for Markdown documents; null for PDFs.
  final String? text;
}

/// Builds one V2 claim draft. Fields that need scientific judgement or
/// manual checking stay empty so `check-research.py --strict-v2` rejects the
/// row until a person completes it.
Map<String, dynamic> claimDraft(
  DraftSource s, {
  required String id,
  required DateTime now,
}) {
  final note = s.note, paper = s.paper.data;
  final quote = note.quote;
  final bound = s.text != null && quote.isNotEmpty && s.text!.contains(quote);
  return {
    'schema_version': 2,
    'id': id,
    'rev': 1,
    'updated_at': now.toUtc().toIso8601String(),
    'paper_id': s.binding.paperId,
    'paper_rev': s.binding.paperRev,
    'statement': note.text,
    'basis': 'full_text',
    'locator': {
      'version': paper['version'],
      'pdf_page': note.pageNumber,
      'page': null,
    },
    'locator_reliability': null,
    'evidence_kind': note.evidenceKind,
    'supports_statement': null,
    'does_not_support': [
      if (note.doesNotSupport.isNotEmpty) note.doesNotSupport,
    ],
    'scope': null,
    'conflicts': <dynamic>[],
    if (bound)
      'text_binding': {
        'path': s.projectPath,
        'sha256': s.document.sha256,
        'excerpt': quote,
      },
    'material_access': bound ? 'available' : 'unchecked',
    'review_status': 'needs_review',
    'workbench': {
      'note_id': note.id,
      'document_path': s.projectPath,
      'document_sha256': s.document.sha256,
      'hash_mismatch': !s.binding.hashOk,
      'quote': quote,
      'pdf_page': note.pageNumber,
      'exported_at': now.toUtc().toIso8601String(),
      'app_version': appVersion,
    },
  };
}

/// Fields a person must still fill before appending a draft.
List<String> missingDraftFields(Map<String, dynamic> row) => [
  if ((row['locator'] as Map)['page'] == null) 'locator.page',
  if (row['locator_reliability'] == null) 'locator_reliability',
  if (row['evidence_kind'] == null) 'evidence_kind',
  if (row['supports_statement'] == null) 'supports_statement',
  if ((row['does_not_support'] as List).isEmpty) 'does_not_support',
  if (row['scope'] == null) 'scope',
];

/// Matches pubspec.yaml; recorded in drafts for provenance only.
const appVersion = '0.1.0+1';

String stripBom(String text) =>
    text.startsWith('\uFEFF') ? text.substring(1) : text;
String encodeJsonl(Iterable<Map<String, dynamic>> rows) =>
    rows.map((r) => '${jsonEncode(r)}\n').join();
