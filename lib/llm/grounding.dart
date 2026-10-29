import '../core/timeline.dart';
import '../db/database.dart';

/// A note selected into the LLM context, with the short citation id the
/// model is told to use.
class ContextNote {
  final String citationId;
  final NoteRow note;

  const ContextNote({required this.citationId, required this.note});
}

/// The result of context selection: which notes made it in, in prompt
/// order, plus whether the library had to be truncated.
class ContextSelection {
  final List<ContextNote> notes;
  final int totalNotes;
  final int usedChars;

  const ContextSelection({
    required this.notes,
    required this.totalNotes,
    required this.usedChars,
  });

  bool get isTruncated => notes.length < totalNotes;
  bool get isEmpty => notes.isEmpty;
}

/// Relevance score for one note against the query terms. Deterministic and
/// embedding-free: term overlap dominates, with small boosts for pinned
/// notes and recent entries. When the query has no terms, ordering is pure
/// recency.
double scoreNote(NoteRow note, Set<String> terms, int recencyRank) {
  if (terms.isEmpty) return -recencyRank.toDouble();
  final content = note.content.toLowerCase();
  var hits = 0;
  for (final term in terms) {
    if (content.contains(term)) hits++;
  }
  if (hits == 0) return -1000.0 - recencyRank;
  return hits * 2.0 + (note.pinned ? 1.0 : 0.0) - recencyRank * 0.01;
}

/// Selects notes to ground a question, respecting a character budget.
///
/// Rules: without query terms, notes fill newest-first until the budget.
/// With terms, only notes containing at least one term are candidates
/// (score-ordered); if nothing at all matches, selection falls back to
/// newest-first so the model still has something to work with. The prompt
/// block itself is always emitted newest-first, so the model reads a
/// chronological journal.
ContextSelection selectContext(
  List<NoteRow> notes,
  String query, {
  int maxChars = 24000,
}) {
  final terms = queryTerms(query);
  var ranked = List<int>.generate(notes.length, (i) => i);
  if (terms.isNotEmpty) {
    final matching = ranked
        .where((i) => scoreNote(notes[i], terms, i) > -1000)
        .toList();
    if (matching.isNotEmpty) {
      matching.sort((a, b) => scoreNote(notes[b], terms, b)
          .compareTo(scoreNote(notes[a], terms, a)));
      ranked = matching;
    }
  }

  // Greedy pack by relevance, then re-order chosen notes newest-first.
  var usedChars = 0;
  final chosenIndexes = <int>[];
  for (final index in ranked) {
    final cost = notes[index].content.length + 48;
    if (chosenIndexes.isNotEmpty && usedChars + cost > maxChars) continue;
    chosenIndexes.add(index);
    usedChars += cost;
  }
  chosenIndexes.sort((a, b) => notes[b].createdAt.compareTo(notes[a].createdAt));

  final selected = [
    for (var i = 0; i < chosenIndexes.length; i++)
      ContextNote(citationId: 'n${i + 1}', note: notes[chosenIndexes[i]]),
  ];
  return ContextSelection(
    notes: selected,
    totalNotes: notes.length,
    usedChars: usedChars,
  );
}

/// Lowercased query words worth matching (length ≥ 3). No stemming; notes
/// are informal and short, so substring containment covers most cases.
Set<String> queryTerms(String query) {
  return query
      .toLowerCase()
      .split(RegExp(r'[^\w]+'))
      .where((w) => w.length >= 3)
      .toSet();
}

/// Builds the system prompt that grounds the model in the selected notes.
///
/// [now] anchors the prompt in the present so relative day names resolve:
/// without it the model cannot tell whether "Thursday" means last week,
/// this week or the upcoming one. Defaults to the current local time.
String buildGroundedSystemPrompt(
  ContextSelection selection, {
  DateTime? now,
}) {
  final today = now ?? DateTime.now();
  final buffer = StringBuffer()
    ..writeln(
        'You are helping the user with their personal notes from JotLock, '
        'a minimal notes app. The notes are raw thoughts: typos, shorthand '
        'and unfinished checklist lines are normal.')
    ..writeln()
    ..writeln('Today is ${formatFull(today)}.')
    ..writeln(
        'Resolve relative day names (today, tomorrow, "Thursday") against '
        'today. A [nX] timestamp is when the note was written; day names '
        'inside note text are the event dates. When the user asks about a '
        'day, also surface notes timestamped on that day, even if their '
        'text does not name it.')
    ..writeln()
    ..writeln('NOTES (newest first):');
  for (final entry in selection.notes) {
    final date = formatFull(entry.note.createdDateTime);
    buffer.writeln('[${entry.citationId}] $date: ${entry.note.content}');
    if (entry.note.hasReminder && !entry.note.isRecurring) {
      buffer.writeln('    (reminder: ${formatFull(entry.note.reminderTime)})');
    }
  }
  buffer
    ..writeln()
    ..writeln('Rules:')
    ..writeln('- Answer ONLY from the notes above.')
    ..writeln(
        '- If the notes do not contain the answer, say so plainly instead '
        'of guessing.')
    ..writeln('- Cite the notes you used, like [n2].')
    ..writeln('- Be concise.');
  return buffer.toString();
}
