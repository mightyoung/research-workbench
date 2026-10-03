import 'package:flutter/material.dart';

import '../core/store.dart';

const _newSection = '';

/// Cites [evidenceId] in an outline section the user picks, or in a new one.
/// Returns the section heading when linked, null when cancelled.
Future<String?> linkToOutline(
  BuildContext context,
  WorkbenchStore store,
  String projectId,
  String evidenceId,
) async {
  final sections = store.sections(projectId);
  final cited = {
    for (final row in store.outline(projectId))
      if (row['evidence_id'] == evidenceId) row['section_id'],
  };
  var choice = sections.isEmpty ? _newSection : sections.last.id;
  final heading = TextEditingController(text: '研究结果与讨论');
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, update) => AlertDialog(
        title: const Text('关联提纲段落'),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (sections.isNotEmpty)
                DropdownButtonFormField<String>(
                  initialValue: choice,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: '提纲段落'),
                  items: [
                    for (final s in sections)
                      DropdownMenuItem(
                        value: s.id,
                        child: Text(
                          '${'　' * (s.level - 1)}${s.heading}'
                          '${cited.contains(s.id) ? ' · 已引用' : ''}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    const DropdownMenuItem(
                      value: _newSection,
                      child: Text('新建段落…'),
                    ),
                  ],
                  onChanged: (v) => update(() => choice = v!),
                ),
              if (choice == _newSection)
                TextField(
                  controller: heading,
                  decoration: const InputDecoration(labelText: '段落标题'),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('关联'),
          ),
        ],
      ),
    ),
  );
  if (ok != true) return null;
  if (choice != _newSection) {
    store.cite(choice, evidenceId);
    return sections.firstWhere((s) => s.id == choice).heading;
  }
  final title = heading.text.trim();
  if (title.isEmpty) return null;
  // Same-named sections are reused rather than duplicated.
  store.addOutline(projectId, title, evidenceId);
  return title;
}
