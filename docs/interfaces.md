# Shared interfaces

`lib/core/models.dart`
- ResearchEntry { String id, projectId, kind, title; Map<String,dynamic> data; } (kind papers/claims/opportunities/experiments/other)
- ResearchDocument { String id, projectId, relativePath, absolutePath; String get title; bool get isPdf; }
- ResearchProject { String id, title, question, nextStep; }
- ResearchTask { String id, projectId, title, goal; int revision; Map<String,dynamic> spec; }
- ResearchRun { String id, taskId, status; int taskRevision; bool accepted; Map<String,dynamic> data; }
- ReadingNote { String id, documentId, locator, text; }

`lib/core/store.dart` WorkbenchStore.open(String rootPath); `.rootPath`; `.close()`; methods synchronous unless explicitly Future:
`projects()` -> List<ResearchProject>; `documents(String projectId)` -> List<ResearchDocument>; `entries(String projectId,{String? kind})` -> List<ResearchEntry>; `tasks(String projectId)` -> List<ResearchTask>; `runs(String projectId)` -> List<ResearchRun>; `notes(String documentId)` -> List<ReadingNote>;
`saveProject(String id,{required String question,required String nextStep})`;
`saveNote(String documentId,String locator,String text)`;
`saveTask({String? id,required String projectId,required String title,required String goal,required Map<String,dynamic> spec})` -> ResearchTask;
`acceptRun(String runId)`;
`addOutline(String projectId,String heading,String evidenceId)`;
`outline(String projectId)` -> List<Map<String,dynamic>>;

`lib/core/exchange.dart` ResearchExchange(WorkbenchStore store):
`Future<ResearchProject> importResearch(String directoryOrZipPath)`;
`Future<String> exportTask(ResearchTask task,String destinationDirectory)`;
`Future<ResearchRun> importResult(String jsonOrZipPath)`;
`Future<String> exportReport(String projectId,String destinationDirectory)`;

`lib/reader/reader_page.dart` ReaderPage({required WorkbenchStore store,required ResearchDocument document,VoidCallback? onChanged}); independent Scaffold route. PDF uses pdfrx; Markdown flutter_markdown_plus. Only local document links within imported project may open; external URLs display as copyable text, never auto-launch.
