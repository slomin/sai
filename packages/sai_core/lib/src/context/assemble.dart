import 'dart:convert';

import '../llm/call.dart';
import '../llm/recorder.dart';
import '../proposals/schema.dart';
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

/// Thrown when what remains after every permitted cut still encodes past
/// the archive's recordable size (#105): what cannot be recorded is not
/// sent — and, measured here in assembly, nothing was written first.
final class ContextSizeError implements Exception {
  const ContextSizeError(this.bytes, this.limit);

  /// The exact encoded size of the irreducible request payload.
  final int bytes;

  /// [maxRecordedTextBytes].
  final int limit;

  @override
  String toString() =>
      'the request would take $bytes bytes once recorded; '
      'the archive allows $limit';
}

/// The one-word user line a warm-up carries: chat templates refuse a
/// prompt with no user message (Qwen's jinja: "No user query found"),
/// and the divergence it causes sits after the shared prefix, so the
/// cached profile and catalog still serve the real turn.
const warmupPrompt = 'ready?';

/// The shared prefix of every catalog turn as a request of its own
/// (#105): the profile and the whole catalog, the [warmupPrompt] line
/// the template demands, one reply token. Sent ahead by the cache
/// warmer, it lets a local endpoint ingest and cache the expensive
/// prefix in the background, so the next real turn pays only for its
/// own tail. Byte-identical to a turn's leading messages by
/// construction — same profile, same renderer, same splice — and
/// [reasoningEffort] mirrors the chat's so the served template cannot
/// differ.
LlmRequest assembleWarmup({
  required String profile,
  required TaskProjection projection,
  required CalendarDate today,
  ReasoningEffort? reasoningEffort,
}) {
  if (profile.isEmpty) throw ArgumentError('profile must not be empty');
  return LlmRequest(
    messages: [
      LlmMessage(LlmRole.system, profile),
      const LlmMessage(LlmRole.user, warmupPrompt),
    ],
    maxTokens: 1,
    taskContext: taskCatalog(projection, today: today),
    taskContextProvenance: TaskProvenance.catalog,
    reasoningEffort: reasoningEffort,
  );
}

/// The explicit trigger's request when the person asks with an empty
/// draft. Directive on purpose: asked with the generic wording, the
/// LAN Qwen answered an honest empty list.
const defaultProposalRequest =
    'Look over my list and suggest the most useful changes';

/// What a model-triggered follow-up call asks for (#35).
const autoProposalRequest = 'Propose the changes you have in mind.';

/// The proposal turn's user message: the request wrapped in the rules
/// the schema cannot carry. Rides as the last user message — never a
/// leading system message, which would push the catalog splice and
/// break the warmed prefix.
String proposalInstruction(String request) =>
    'Propose changes to the task list as structured suggestions.\n'
    'Rules: reference a task only by its handle from the catalog '
    '(t1, t2, …); only Open tasks carry handles. Kinds: "schedule" sets '
    'when (today, tomorrow, someday, anytime or YYYY-MM-DD); "deadline" '
    'sets deadline (today, tomorrow, none or YYYY-MM-DD); "split" '
    'replaces one task with 2–8 new titles in parts. At most 8 '
    'suggestions, each with one short reason; suggest only what the '
    'request calls for — an empty list is a fine answer.\n'
    'Request: $request';

/// A proposal turn's request (#35): the same profile-and-catalog prefix
/// as every catalog turn — byte-identical, so the warmed cache serves
/// it — with the schema on [LlmRequest.responseSchema] and the
/// instruction in the user message.
AssembledContext assembleProposal({
  required String profile,
  String? memory,
  required TaskProjection projection,
  required CalendarDate today,
  required List<LlmMessage> history,
  required String request,
  ContextBudget budget = defaultContextBudget,
  ReasoningEffort? reasoningEffort,
}) => assembleContext(
  profile: profile,
  memory: memory,
  projection: projection,
  today: today,
  history: history,
  draft: proposalInstruction(request),
  budget: budget,
  reasoningEffort: reasoningEffort,
  shape: TaskContextShape.catalog,
  responseSchema: proposalResponseSchema,
);

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
  ReasoningEffort? reasoningEffort,
  TaskContextShape shape = TaskContextShape.compact,
  ResponseSchema? responseSchema,
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

  (LlmRequest, int, int) build() {
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
      reasoningEffort: reasoningEffort,
      responseSchema: responseSchema,
    );
    final estimate = request.sent.fold(0, (n, m) => n + estimateTokens(m.text));
    return (request, estimate, recordedRequestBytes(request));
  }

  // Two ceilings, deliberately in different units (#105): the token
  // estimate against the model's window, and the payload's exact encoded
  // size against what the archive records — measured here, before the
  // user's line is written, so an oversized turn refuses atomically.
  var (request, estimate, bytes) = build();
  bool over() => estimate > budget.available || bytes > maxRecordedTextBytes;
  var droppedTurns = 0;
  while (over() && keptHistory.isNotEmpty) {
    final cut = keptHistory.length >= 2 ? 2 : 1;
    keptHistory = keptHistory.sublist(cut);
    droppedTurns += cut;
    (request, estimate, bytes) = build();
  }
  if (droppedTurns > 0) dropped.add('turns:$droppedTurns');
  while (over() && keptDays > 0) {
    keptDays--;
    dropped.add('upcoming:${upcomingDays[keptDays].title}');
    (request, estimate, bytes) = build();
  }
  if (over() && keptMemory != null) {
    keptMemory = null;
    dropped.add('memory');
    (request, estimate, bytes) = build();
  }
  if (estimate > budget.available) {
    throw ContextBudgetError(estimate, budget);
  }
  if (bytes > maxRecordedTextBytes) {
    throw ContextSizeError(bytes, maxRecordedTextBytes);
  }
  return AssembledContext(
    request: request,
    dropped: dropped,
    estimatedTokens: estimate,
  );
}
