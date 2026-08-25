/// Undo as the archive demands it: never a rewrite, always a new event.
/// Each event owns its inverse ([TaskEvent.invert]); this is the entry
/// point the store calls.
library;

import '../archive/blobref.dart';
import 'events.dart';
import 'undo_state.dart';

/// The single event that puts the entity [event] touched back the way
/// [before] had it — see [TaskEvent.invert] for the contract. [created]
/// is the id the append minted: the entity id for a `*.create`, unused
/// otherwise.
TaskEvent invertEvent(
  TaskEvent event,
  UndoState before, {
  required BlobRef created,
}) => event.invert(before, created: created);
