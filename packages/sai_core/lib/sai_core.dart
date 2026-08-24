/// Core of sai: shared state, models and services used by every client.
///
/// Clients (`apps/sai_app`, `apps/sai_tui`) depend on this package; this
/// package never depends on a client or on Flutter.
library;

export 'src/app_info.dart';
export 'src/archive.dart';
export 'src/providers.dart';
export 'src/tasks.dart';
