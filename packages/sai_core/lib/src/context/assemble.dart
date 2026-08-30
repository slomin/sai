import 'dart:convert';

import '../llm/call.dart';
import '../tasks/capture.dart';
import '../tasks/date.dart';
import '../tasks/lists.dart';
import '../tasks/model.dart';
import '../tasks/projection.dart';
import '../tasks/sidebar.dart';
import '../tasks/views.dart';
import 'catalog.dart';

/// Which task context a turn carries (#105): compact — Today and
/// Upcoming, what a cloud provider may see; catalog — the complete
/// collection, local providers only. The caller maps the provider's
/// privacy tag to a shape; assembly itself knows nothing of providers.
enum TaskContextShape { compact, catalog }

/// The assistant's standing instructions until the profile (#31) exists.
/// Provider-independent: the same text goes to every model.
const defaultProfile =
    'You are sai, a personal assistant for one person\'s task list.\n'
    'Answer questions about the list from the task context you are given: '
    'what is due, what is coming up, what the day looks like. Quote task '
    'titles as they appear. Be brief and concrete; when you are unsure, '
    'say so rather than guess.\n'
    'You cannot change the list. If the task context is missing, say that '
    'you cannot see the list right now.';

/// What one call may take, in estimated tokens.
final class ContextBudget {
  const ContextBudget({required this.maxTokens, required this.replyReserve});

  /// The model's whole window as the caller believes it to be.
  final int maxTokens;

  /// Room kept for the answer; also the request's `max_tokens`.
  final int replyReserve;

  /// What the prompt may use.
  int get available => maxTokens - replyReserve;
}

/// Where no endpoint says otherwise: a window every local model of
/// interest has, with half kept for the answer — a model that thinks
/// before it answers spends its reasoning from the same `max_tokens`,
/// and a reserve of 1 024 was seen to run out before the first word.
const defaultContextBudget = ContextBudget(maxTokens: 8000, replyReserve: 4096);

/// A conservative estimate: one token per four bytes of UTF-8, rounded
/// up. There is no tokenizer in the repository; the budget is a guard,
/// not an accounting.
int estimateTokens(String text) => (utf8.encode(text).length + 3) ~/ 4;

/// The lists as the model sees them: Today and Upcoming, one line per
/// task in the capture form both clients render, Upcoming grouped by day
/// exactly as the app's view. [upcomingDays] caps the days shown, nearest
/// first; the cut is stated in the text so the model does not mistake a
/// shortened list for the whole one.
String taskContextFor(
  TaskProjection projection,
  CalendarDate today, {
  int? upcomingDays,
}) {
  final out = StringBuffer('Today is $today.\n');
  final todays = projection.list(TaskList.today, today: today);
  _section(out, listTitle(TaskList.today), todays, today);
  final days = taskView(
    projection,
    const ListSection(TaskList.upcoming),
    today: today,
  ).sections;
  final shown = upcomingDays == null || upcomingDays >= days.length
      ? days
      : days.sublist(0, upcomingDays);
  final count = [for (final d in shown) ...d.tasks].length;
  if (shown.isEmpty) {
    out.write('${listTitle(TaskList.upcoming)} (0): none\n');
  } else {
    out.write('${listTitle(TaskList.upcoming)} ($count):\n');
    for (final day in shown) {
      out.write('${day.title}:\n');
      for (final task in day.tasks) {
        out.write('- ${formatQuickCapture(task, today: today)}\n');
      }
    }
  }
  final hidden = days.length - shown.length;
  if (hidden > 0) {
    out.write('($hidden more ${hidden == 1 ? 'day' : 'days'} not shown)\n');
  }
  return out.toString().trimRight();
}

void _section(
  StringBuffer out,
  String title,
  List<Task> tasks,
  CalendarDate today,
) {
  if (tasks.isEmpty) {
    out.write('$title (0): none\n');
    return;
  }
  out.write('$title (${tasks.length}):\n');
  for (final task in tasks) {
    out.write('- ${formatQuickCapture(task, today: today)}\n');
  }
}

/// The request [assembleContext] built, and what it left out to fit.
final class AssembledContext {
  AssembledContext({
    required this.request,
    required List<String> dropped,
    required this.estimatedTokens,
  }) : dropped = List.unmodifiable(dropped);

  final LlmRequest request;

  /// What the budget cost, in order: `turns:N` (oldest messages),
  /// `upcoming:YYYY-MM-DD` (farthest days), `memory`.
  final List<String> dropped;

  /// The note a client shows beside an answer that went without part of
  /// its context; null when nothing was cut.
  static String? cutNote(List<String> dropped) =>
      dropped.isEmpty ? null : 'context cut: ${dropped.join(' · ')}';

  /// The estimate for the prompt as built.
  final int estimatedTokens;
}

/// Thrown when the profile, Today and the current message alone exceed
/// the budget: nothing else is left to cut.
final class ContextBudgetError implements Exception {
  const ContextBudgetError(this.estimatedTokens, this.budget);

  final int estimatedTokens;
  final ContextBudget budget;

  @override
  String toString() =>
      'the message and today\'s list need ~$estimatedTokens tokens; '
      'the budget allows ${budget.available}';
}

/// Builds the one request a chat turn sends (ADR 0011). Pure and
/// deterministic: the same inputs give the same request and hash.
///
/// Messages are `system` [profile], `system` [memory] when given, then
/// [history] as it stands, then the user's [draft]. The lists travel on
/// [LlmRequest.taskContext], never in a message of the caller's own, so
/// the recorder can withhold them from a cloud provider (ADR 0010).
///
/// When the estimate exceeds [budget], cuts go in a fixed order until it
/// fits — for the compact [shape]: the oldest [history] messages, then
/// Upcoming days from the farthest back, then memory; for the catalog
/// shape: turns, then memory — the catalog itself is never cut (#105).
/// Today and the profile are never cut; past that, [ContextBudgetError].
AssembledContext assembleContext({
  required String profile,
  String? memory,
  required TaskProjection projection,
  required CalendarDate today,
  required List<LlmMessage> history,
  required String draft,
  ContextBudget budget = defaultContextBudget,
  bool? reasoning,
  TaskContextShape shape = TaskContextShape.compact,
}) {
  final message = draft.trim();
  if (message.isEmpty) throw ArgumentError('draft must not be blank');
  if (profile.isEmpty) throw ArgumentError('profile must not be empty');
  if (memory != null && memory.isEmpty) {
    throw ArgumentError('memory must be null or non-empty');
  }
  // Rendered once and never shrunk; null on the compact path, where the
  // context is re-rendered per cut instead.
  final catalog = shape == TaskContextShape.catalog
      ? taskCatalog(projection, today: today)
      : null;
  final upcomingDays = shape == TaskContextShape.compact
      ? taskView(
          projection,
          const ListSection(TaskList.upcoming),
          today: today,
        ).sections
      : const <TaskViewSection>[];

  var keptHistory = history;
  var keptDays = upcomingDays.length;
  var keptMemory = memory;
  final dropped = <String>[];

  (LlmRequest, int) build() {
    final tasks =
        catalog ?? taskContextFor(projection, today, upcomingDays: keptDays);
    final notes = keptMemory;
    final request = LlmRequest(
      messages: [
        LlmMessage(LlmRole.system, profile),
        if (notes != null) LlmMessage(LlmRole.system, notes),
        ...keptHistory,
        LlmMessage(LlmRole.user, message),
      ],
      maxTokens: budget.replyReserve,
      taskContext: tasks,
      taskContextProvenance: catalog != null
          ? TaskProvenance.catalog
          : TaskProvenance.compact,
      reasoning: reasoning,
    );
    final estimate = request.sent.fold(0, (n, m) => n + estimateTokens(m.text));
    return (request, estimate);
  }

  var (request, estimate) = build();
  var droppedTurns = 0;
  while (estimate > budget.available && keptHistory.isNotEmpty) {
    final cut = keptHistory.length >= 2 ? 2 : 1;
    keptHistory = keptHistory.sublist(cut);
    droppedTurns += cut;
    (request, estimate) = build();
  }
  if (droppedTurns > 0) dropped.add('turns:$droppedTurns');
  while (estimate > budget.available && keptDays > 0) {
    keptDays--;
    dropped.add('upcoming:${upcomingDays[keptDays].title}');
    (request, estimate) = build();
  }
  if (estimate > budget.available && keptMemory != null) {
    keptMemory = null;
    dropped.add('memory');
    (request, estimate) = build();
  }
  if (estimate > budget.available) {
    throw ContextBudgetError(estimate, budget);
  }
  return AssembledContext(
    request: request,
    dropped: dropped,
    estimatedTokens: estimate,
  );
}
