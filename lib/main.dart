import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'core/store.dart';
import 'core/exchange.dart';
import 'app/workbench_app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    const configuredRoot = String.fromEnvironment('WORKBENCH_DATA_DIR');
    final root = configuredRoot.isNotEmpty ? Directory(configuredRoot) :
      Directory('${(await getApplicationSupportDirectory()).path}/research-workbench');
    final store = WorkbenchStore.open(root.path);
    const demo = String.fromEnvironment('DEMO_RESEARCH_DIR');
    // This opt-in developer define imports a snapshot; never executes source code.
    if (demo.isNotEmpty && store.projects().isEmpty) {
      await ResearchExchange(store).importResearch(demo);
    }
    runApp(WorkbenchApp(store:store));
  } catch (error) {
    runApp(MaterialApp(home:Scaffold(body:SafeArea(child:Padding(
      padding:const EdgeInsets.all(32),child:SelectableText('无法打开本地工作台\n$error'))))));
  }
}
