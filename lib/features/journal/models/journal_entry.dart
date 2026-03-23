// =============================================================================
// features/journal/models/journal_entry.dart — Journal entry data model
// =============================================================================
// Enums:
//   TradeMood { confident, neutral, anxious, frustrated, excited }
//
// TradeMoodExt (extension):
//   .emoji  — single emoji string shown in _JournalCard and AddJournalScreen
//             mood picker (😎 😐 😰 😤 🚀)
//   .label  — capitalized name shown below emoji in mood picker
//
// JournalEntry (class):
//   Fields:  id, userId, tradeId?, title, body, mood?, tags[], createdAt
//
//   Serialization:
//     fromJson() — called by journalProvider when reading from Supabase
//                  'journal_entries' table
//     toJson()   — called by JournalNotifier.addEntry() when inserting;
//                  excludes id/userId/createdAt (set server-side)
//
//   Used in:
//     • JournalScreen     (_JournalCard) — mood emoji, title, body preview, tags, date
//     • AddJournalScreen               — mood picker, title/body fields, tag chips
//     • journalProvider / JournalNotifier (journal_provider.dart)
// =============================================================================
enum TradeMood { confident, neutral, anxious, frustrated, excited }

extension TradeMoodExt on TradeMood {
  String get emoji => switch (this) {
        TradeMood.confident => '😎',
        TradeMood.neutral => '😐',
        TradeMood.anxious => '😰',
        TradeMood.frustrated => '😤',
        TradeMood.excited => '🚀',
      };
  String get label => name[0].toUpperCase() + name.substring(1);
}

class JournalEntry {
  final String id;
  final String userId;
  final String? tradeId;
  final String title;
  final String body;
  final TradeMood? mood;
  final List<String> tags;
  final DateTime createdAt;

  const JournalEntry({
    required this.id,
    required this.userId,
    this.tradeId,
    required this.title,
    required this.body,
    this.mood,
    required this.tags,
    required this.createdAt,
  });

  factory JournalEntry.fromJson(Map<String, dynamic> json) => JournalEntry(
        id: json['id'] as String,
        userId: json['user_id'] as String,
        tradeId: json['trade_id'] as String?,
        title: json['title'] as String,
        body: json['body'] as String,
        mood: json['mood'] != null
            ? TradeMood.values.firstWhere((m) => m.name == json['mood'],
                orElse: () => TradeMood.neutral)
            : null,
        tags: json['tags'] != null
            ? List<String>.from(json['tags'] as List)
            : [],
        createdAt: DateTime.parse(json['created_at'] as String),
      );

  Map<String, dynamic> toJson() => {
        'title': title,
        'body': body,
        'mood': mood?.name,
        'trade_id': tradeId,
        'tags': tags,
      };
}
