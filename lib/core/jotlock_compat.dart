import 'package:flutter/material.dart';

/// Pure helpers ported from jotlock so imported notes render with exactly
/// the semantics the capture app gave them: checklist line syntax, reminder
/// repeat labels, and the priority color palette (index-addressed, so old
/// backups keep their colors).

/// A checklist item parsed from a note's text. Checklists are plain text:
/// a line starting with `[ ]` is an open item, `[x]`/`[X]` a done one.
class ChecklistItem {
  /// Index of this line within `note.content.split('\n')`.
  final int lineIndex;
  final bool checked;
  final String label;

  const ChecklistItem({
    required this.lineIndex,
    required this.checked,
    required this.label,
  });
}

/// Matches an entire checklist line: optional leading whitespace, the
/// `[ ] / [x]` marker, an optional single space, then the label.
final RegExp _checklistLine = RegExp(
  r'^(?<indent>[ \t]*)\[(?<mark>[ xX])\](?<space> ?)(?<label>.*)$',
);

/// Parses [text] into its checklist items, in order.
List<ChecklistItem> checklistItems(String text) {
  final lines = text.split('\n');
  final result = <ChecklistItem>[];
  for (var i = 0; i < lines.length; i++) {
    final match = _checklistLine.firstMatch(lines[i]);
    if (match == null) continue;
    result.add(ChecklistItem(
      lineIndex: i,
      checked: match.namedGroup('mark') != ' ',
      label: (match.namedGroup('label') ?? '').trim(),
    ));
  }
  return result;
}

/// The checklist item on line [lineIndex] of [text], or null when that
/// line is not a checklist item.
ChecklistItem? checklistItemAt(String text, int lineIndex) {
  final lines = text.split('\n');
  if (lineIndex < 0 || lineIndex >= lines.length) return null;
  final match = _checklistLine.firstMatch(lines[lineIndex]);
  if (match == null) return null;
  return ChecklistItem(
    lineIndex: lineIndex,
    checked: match.namedGroup('mark') != ' ',
    label: (match.namedGroup('label') ?? '').trim(),
  );
}

/// (checked, total) counts of the checklist items in [text].
(int, int) checklistProgress(String text) {
  final items = checklistItems(text);
  return (items.where((i) => i.checked).length, items.length);
}

/// Human label for a repeat interval in days ('' when one-shot).
String repeatLabel(int repeatDays) {
  switch (repeatDays) {
    case 0:
      return '';
    case 1:
      return 'daily';
    case 7:
      return 'weekly';
    default:
      return 'every $repeatDays days';
  }
}

/// Fixed priority palette from jotlock's note_colors.dart. `0` means
/// "no color"; index-addressed entries (`colorIndex - 1` picks from the
/// list) keep backups rendering identically across theme changes.
const int noColorIndex = 0;

const List<Color> noteColors = [
  Color(0xFFE53935), // red
  Color(0xFFFB8C00), // orange
  Color(0xFFF9A825), // yellow / amber
  Color(0xFF43A047), // green
  Color(0xFF1E88E5), // blue
  Color(0xFF8E24AA), // purple
  Color(0xFF00897B), // teal
];

/// Card background for a colored note: a low-alpha blend of the palette
/// color over the theme surface. Returns null when [colorIndex] is out of
/// range (no tint needed).
Color? noteCardColor(int colorIndex, ColorScheme scheme) {
  if (colorIndex <= noColorIndex || colorIndex > noteColors.length) return null;
  final base = scheme.surfaceContainerHighest;
  return Color.alphaBlend(noteColors[colorIndex - 1].withAlpha(46), base);
}
