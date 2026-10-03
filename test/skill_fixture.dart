import 'dart:convert';

import 'package:crypto/crypto.dart';

// Handwritten fixture shaped after research-skill v6.5 (no upstream files copied).
const skillPdf = '%PDF-1.4 synthetic\n%%EOF';
const skillMd = '# 获取材料\n\n召回与排序分开评估。\n';
String skillSha(String s) => sha256.convert(utf8.encode(s)).toString();
String _rows(List<Map<String, dynamic>> rows) => rows
    .map(
      (r) =>
          '${jsonEncode({'schema_version': 2, 'updated_at': '2026-10-01T12:00:00Z', ...r})}\n',
    )
    .join();

Map<String, String> skillProject() => {
  'research/sources.jsonl': _rows([
    {
      'id': 's1',
      'rev': 1,
      'url': 'https://example.invalid/1',
      'status': 'active',
    },
    {
      'id': 's2',
      'rev': 1,
      'url': 'https://example.invalid/2',
      'status': 'active',
      'material_binding': {
        'path': 'related_work/acquired/h/snap/notes.md',
        'sha256': skillSha(skillMd),
      },
    },
  ]),
  'research/papers.jsonl': _rows([
    {
      'id': 'p1-v1',
      'rev': 1,
      'source_id': 's1',
      'source_rev': 1,
      'arxiv_id': '2301.00001',
      'version': 'v1',
      'title': '旧标题',
      'reading_depth': 'metadata',
      'review_status': 'current',
    },
    {
      'id': 'p1-v1',
      'rev': 2,
      'source_id': 's1',
      'source_rev': 1,
      'arxiv_id': '2301.00001',
      'version': 'v1',
      'title': '合成论文',
      'reading_depth': 'abstract',
      'review_status': 'current',
    },
    {
      'id': 'p2',
      'rev': 1,
      'source_id': 's2',
      'source_rev': 1,
      'version': 'published',
      'title': '获取的论文',
      'reading_depth': 'metadata',
      'review_status': 'needs_review',
    },
    {
      'id': 'p-old',
      'rev': 1,
      'source_id': 's1',
      'source_rev': 1,
      'title': '退役',
      'active': false,
      'review_note': 'superseded',
    },
  ]),
  'research/claims.jsonl': _rows([
    {
      'id': 'c1',
      'rev': 1,
      'paper_id': 'p1-v1',
      'paper_rev': 1,
      'statement': '初稿',
      'review_status': 'current',
    },
    {
      'id': 'c1',
      'rev': 2,
      'paper_id': 'p1-v1',
      'paper_rev': 2,
      'statement': '修订后',
      'review_status': 'needs_review',
    },
  ]),
  'research/opportunities.jsonl': _rows([
    {
      'id': 'o1',
      'rev': 1,
      'title': '候选',
      'status': 'candidate',
      'supports': [
        {'id': 'c1', 'rev': 2},
      ],
      'refutes': [],
    },
  ]),
  'research/tensions.jsonl': _rows([
    {'id': 't1', 'rev': 1, 'observation': '增益与调优混淆'},
  ]),
  'landscape.md': '# 地图\n\n见 [claims/c1@2]。\n',
  'related_work/p1/versions/v1/paper.pdf': skillPdf,
  'related_work/p1/versions/v1/manifest.json': jsonEncode({
    'arxiv_id': '2301.00001v1',
    'version': 'v1',
    'sha256': {'paper.pdf': skillSha(skillPdf)},
  }),
  'related_work/p1/versions/v1/source/download.bin': 'tex archive',
  'related_work/acquired/h/snap/notes.md': skillMd,
  'DataSet/train.csv': 'a,b\n',
  'experiment/run1/checkpoints/step1.bin': 'weights',
  'model.pt': 'weights',
};
