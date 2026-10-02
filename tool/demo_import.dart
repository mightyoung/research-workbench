import 'dart:convert';
import 'dart:io';
import 'package:research_workbench/core/exchange.dart';
import 'package:research_workbench/core/store.dart';

/// Reads research files and creates a separate app snapshot. Never runs research code.
Future<void> main(List<String> args) async {
  if (args.length != 2) {
    stderr.writeln(
      'Usage: dart run tool/demo_import.dart <research directory or ZIP> <app data directory>',
    );
    exitCode = 64;
    return;
  }
  final store = WorkbenchStore.open(args[1]);
  try {
    final project = await ResearchExchange(store).importResearch(args[0]);
    stdout.writeln(
      jsonEncode({
        'projectId': project.id,
        'title': project.title,
        'documents': store.documents(project.id).length,
        'entries': store.entries(project.id).length,
        'papers': store.entries(project.id, kind: 'papers').length,
        'claims': store.entries(project.id, kind: 'claims').length,
        'opportunities': store
            .entries(project.id, kind: 'opportunities')
            .length,
        'experiments': store.entries(project.id, kind: 'experiments').length,
        'dataDirectory': store.rootPath,
      }),
    );
  } finally {
    store.close();
  }
}
