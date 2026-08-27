/// Where a Things import stands (#40): the closed set of states a client
/// renders, one per screen the flow has. Counts, paths and a uuid at
/// most — never a title.
library;

import 'things_mapping.dart';
import 'things_source.dart';

/// One step of the import flow.
sealed class ThingsImportState {
  const ThingsImportState();
}

/// Nothing started.
final class ImportIdle extends ThingsImportState {
  const ImportIdle();

  @override
  bool operator ==(Object other) => other is ImportIdle;

  @override
  int get hashCode => (ImportIdle).hashCode;

  @override
  String toString() => 'ImportIdle()';
}

/// A database was found or chosen; nothing read yet.
final class ImportSource extends ThingsImportState {
  const ImportSource(this.path);

  final String path;

  @override
  bool operator ==(Object other) => other is ImportSource && other.path == path;

  @override
  int get hashCode => Object.hash(ImportSource, path);

  @override
  String toString() => 'ImportSource($path)';
}

/// The private copy is being taken and read, then planned.
final class ImportReading extends ThingsImportState {
  const ImportReading(this.path);

  final String path;

  @override
  String toString() => 'ImportReading($path)';
}

/// The dry run: what a run would do, as counts, and with which options.
/// The plan itself — which names titles — stays inside the notifier.
final class ImportPlanned extends ThingsImportState {
  const ImportPlanned({
    required this.path,
    required this.report,
    required this.operations,
    required this.options,
  });

  final String path;
  final ImportReport report;

  /// Operations a run would apply; 0 means nothing to do.
  final int operations;
  final ThingsImportOptions options;

  @override
  String toString() => 'ImportPlanned($path, $operations operations)';
}

/// Events are being written.
final class ImportRunning extends ThingsImportState {
  const ImportRunning({
    required this.path,
    required this.done,
    required this.total,
  });

  final String path;
  final int done;
  final int total;

  @override
  String toString() => 'ImportRunning($path, $done/$total)';
}

/// The run finished.
final class ImportDone extends ThingsImportState {
  const ImportDone({
    required this.path,
    required this.report,
    required this.operations,
    required this.eventsAppended,
  });

  final String path;
  final ImportReport report;
  final int operations;
  final int eventsAppended;

  @override
  String toString() => 'ImportDone($path, $eventsAppended events)';
}

/// Something stood in the way; [failure] says what and what to do.
final class ImportFailed extends ThingsImportState {
  const ImportFailed(this.failure, {this.path});

  final ThingsFailure failure;

  /// The database that was being read, when one was named.
  final String? path;

  @override
  String toString() => 'ImportFailed(${failure.runtimeType}, $path)';
}
