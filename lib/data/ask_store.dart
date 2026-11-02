import 'package:drift/drift.dart';

import '../db/database.dart';
import '../llm/llm_client.dart';

/// Persistence for the Ask chat session. One row per message (see
/// [AskMessages]); the whole table is the single active session. Saving
/// rewrites it in one transaction — sessions are small (tens of rows), and
/// rewrite-in-lockstep keeps the screen's parallel lists and the rows from
/// ever disagreeing about order or pairing.

/// Loads the persisted session, oldest first. Empty assistant placeholders
/// are never stored, so a restored session only contains finished turns.
Future<List<AskMessageRow>> loadAskMessages(AppDatabase db) {
  return (db.select(db.askMessages)
        ..orderBy([(t) => OrderingTerm.asc(t.id)]))
      .get();
}

/// Replaces the stored session with [messages] (and their parallel ask
/// [times]). Assistant messages whose content is still empty — a turn that
/// never finished — are skipped, in lockstep with their times.
Future<void> saveAskSession(
  AppDatabase db,
  List<ChatMessage> messages,
  List<DateTime> times,
) {
  return db.transaction(() async {
    await db.delete(db.askMessages).go();
    await db.batch((b) {
      for (var i = 0; i < messages.length; i++) {
        if (messages[i].role == 'assistant' &&
            messages[i].content.trim().isEmpty) {
          continue;
        }
        b.insert(
          db.askMessages,
          AskMessagesCompanion.insert(
            role: messages[i].role,
            content: messages[i].content,
            askedAt: times[i].millisecondsSinceEpoch,
          ),
        );
      }
    });
  });
}

/// Empties the stored session ('Clear chat').
Future<void> clearAskSession(AppDatabase db) =>
    db.delete(db.askMessages).go();
