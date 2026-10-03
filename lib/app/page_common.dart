import 'package:flutter/material.dart';

/// Shared scaffolding for the workbench section pages.
Widget pageLayout(List<Widget> children) => ListView(
  padding: const EdgeInsets.all(20),
  children: [
    for (final child in children)
      Padding(padding: const EdgeInsets.only(bottom: 16), child: child),
  ],
);

class SectionCard extends StatelessWidget {
  const SectionCard(this.title, this.content, {super.key, this.trailing});
  final String title;
  final Widget content;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              ?trailing,
            ],
          ),
          const SizedBox(height: 12),
          content,
        ],
      ),
    ),
  );
}

void showMessage(BuildContext context, String value) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(value)));
}

Future<bool> confirmDialog(
  BuildContext context,
  String title,
  String description,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SelectableText(description),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认'),
          ),
        ],
      ),
    ) ??
    false;

/// Builds a file into the export directory; the host saves it and reports.
typedef ExportFile =
    Future<void> Function(
      Future<String> Function(String directory) build,
      String mimeType,
    );
