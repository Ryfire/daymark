/// Pure timeline helpers: day bucketing and human day/time formatting.
/// Generic over the note type so it stays testable without the database.
library;

/// One day's worth of items, in source order.
class DayGroup<T> {
  final DateTime day;
  final List<T> items;
  const DayGroup({required this.day, required this.items});
}

/// Buckets [items] into calendar days (local time) via [createdAtMs].
/// Days appear in first-encounter order, so feeding newest-first notes
/// yields newest-day-first groups with newest-first items inside.
List<DayGroup<T>> groupByDay<T>(List<T> items, int Function(T) createdAtMs) {
  final days = <DateTime, List<T>>{};
  final order = <DateTime>[];
  for (final item in items) {
    final dt = DateTime.fromMillisecondsSinceEpoch(createdAtMs(item));
    final day = DateTime(dt.year, dt.month, dt.day);
    if (!days.containsKey(day)) {
      days[day] = <T>[];
      order.add(day);
    }
    days[day]!.add(item);
  }
  return [for (final day in order) DayGroup(day: day, items: days[day]!)];
}

const List<String> _weekdays = [
  'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun',
];
const List<String> _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

String _two(int n) => n.toString().padLeft(2, '0');

/// Section header for a timeline day: 'Today', 'Yesterday',
/// 'Mon, Oct 27', or 'Mon, Oct 27, 2025' when the year differs from now.
String dayHeader(DateTime day, {DateTime? now}) {
  final ref = now ?? DateTime.now();
  final today = DateTime(ref.year, ref.month, ref.day);
  final d = DateTime(day.year, day.month, day.day);
  if (d == today) return 'Today';
  if (d == today.subtract(const Duration(days: 1))) return 'Yesterday';
  final base = '${_weekdays[d.weekday - 1]}, ${_months[d.month - 1]} ${d.day}';
  return d.year == ref.year ? base : '$base, ${d.year}';
}

/// '14:32'
String formatTime(DateTime dt) => '${_two(dt.hour)}:${_two(dt.minute)}';

/// 'Oct 27 · 14:32'
String formatShort(DateTime dt) =>
    '${_months[dt.month - 1]} ${dt.day} · ${formatTime(dt)}';

/// 'Mon, Oct 27, 2025 · 14:32' — full detail for the note screen.
String formatFull(DateTime dt) {
  final date =
      '${_weekdays[dt.weekday - 1]}, ${_months[dt.month - 1]} ${dt.day}, ${dt.year}';
  return '$date · ${formatTime(dt)}';
}
