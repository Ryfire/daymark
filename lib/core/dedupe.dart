import '../db/database.dart';

/// Duplicate detection for the library: pure functions over note text,
/// no LLM involved. Exact duplicates ignore case, punctuation, collapsed
/// whitespace and checklist markers; near-duplicates additionally group
/// when their token overlap (Jaccard) reaches [nearDupeThreshold], so a
/// lightly edited variant of the same note still clusters with its
/// original. Comparison is ASCII-based (shorthand capture text); accents
/// are stripped, which can merge look-alike words but never splits them
/// into false negatives.
const double nearDupeThreshold = 0.75;

/// The comparison form of [text]: lowercase, checklist markers and
/// punctuation replaced by spaces, whitespace collapsed. Blank notes
/// normalize to '' and never group with anything.
String normalizeForCompare(String text) {
  final stripped = text
      .toLowerCase()
      .replaceAll(RegExp(r'\[[ x]\]'), ' ')
      .replaceAll(RegExp(r"[^a-z0-9]+"), ' ')
      .trim();
  return stripped.replaceAll(RegExp(r'\s+'), ' ');
}

/// Token set of the normalized text — the Jaccard universe.
Set<String> tokensFor(String text) =>
    normalizeForCompare(text)
        .split(' ')
        .where((token) => token.isNotEmpty)
        .toSet();

/// Jaccard overlap of the two notes' tokens: 0.0 (disjoint) to 1.0
/// (same tokens). Blank text scores 0 so it never matches.
double similarity(String a, String b) {
  final setA = tokensFor(a);
  final setB = tokensFor(b);
  if (setA.isEmpty || setB.isEmpty) return 0;
  return setA.intersection(setB).length / setA.union(setB).length;
}

/// Groups [notes] (any order) into clusters of likely duplicates.
/// Returns only groups of 2+; every note appears in at most one group.
/// Greedy all-pairs clustering — O(n²), fine at personal-library scale.
List<List<NoteRow>> findDuplicateGroups(List<NoteRow> notes) {
  final normalized = [
    for (final note in notes) normalizeForCompare(note.content),
  ];
  final used = List<bool>.filled(notes.length, false);
  final groups = <List<NoteRow>>[];
  for (var i = 0; i < notes.length; i++) {
    if (used[i] || normalized[i].isEmpty) continue;
    used[i] = true;
    final group = <NoteRow>[notes[i]];
    for (var j = i + 1; j < notes.length; j++) {
      if (used[j] || normalized[j].isEmpty) continue;
      final same =
          normalized[j] == normalized[i] ||
          similarity(normalized[i], normalized[j]) >= nearDupeThreshold;
      if (same) {
        used[j] = true;
        group.add(notes[j]);
      }
    }
    if (group.length > 1) groups.add(group);
  }
  return groups;
}
