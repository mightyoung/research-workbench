import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/research_kinds.dart';

/// Record kinds a reading note can be about.
const _noteTargets = {
  'papers',
  'claims',
  'opportunities',
  'tensions',
  'experiments',
  'failures',
};

/// Current revisions of records a note can point at.
List<ResearchEntry> noteTargets(List<ResearchEntry> entries) => latestRevisions(
  entries,
).where((e) => _noteTargets.contains(e.kind)).toList();

String entryLabel(ResearchEntry e) =>
    '${recordKinds[e.kind] ?? e.kind} · ${e.title}';

/// Dropdown of research records; null means "not linked".
class EntryPicker extends StatelessWidget {
  const EntryPicker({
    super.key,
    required this.entries,
    required this.value,
    required this.onChanged,
  });
  final List<ResearchEntry> entries;
  final String? value;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) => DropdownButtonFormField<String?>(
    initialValue: entries.any((e) => e.id == value) ? value : null,
    isExpanded: true,
    decoration: const InputDecoration(labelText: '关联研究对象（可选）'),
    items: [
      const DropdownMenuItem(value: null, child: Text('不关联')),
      for (final e in entries)
        DropdownMenuItem(
          value: e.id,
          child: Text(entryLabel(e), overflow: TextOverflow.ellipsis),
        ),
    ],
    onChanged: onChanged,
  );
}

/// Asks which record a saved note is about. Returns `(id: ...)` on save
/// (id null clears the link) and null on cancel.
Future<({String? id})?> pickNoteEntry(
  BuildContext context,
  List<ResearchEntry> entries,
  String? current,
) {
  var selected = current;
  return showDialog<({String? id})>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('关联研究对象'),
      content: SizedBox(
        width: 480,
        child: EntryPicker(
          entries: entries,
          value: current,
          onChanged: (v) => selected = v,
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('取消')),
        FilledButton(
          onPressed: () => Navigator.pop(c, (id: selected)),
          child: const Text('保存关联'),
        ),
      ],
    ),
  );
}
