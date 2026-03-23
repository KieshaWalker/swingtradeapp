// =============================================================================
// features/journal/screens/journal_screen.dart — Journal feed
// =============================================================================
// Widgets defined here:
//   • JournalScreen  (ConsumerWidget) — scaffold + ListView of _JournalCard;
//                     FAB navigates to /journal/add (AddJournalScreen)
//   • _JournalCard   (StatelessWidget) — card per entry showing:
//                     mood emoji, title, body preview (3 lines), tags (green pills),
//                     date; delete button with confirmation dialog
//
// Route: '/journal' in router.dart, tab index 3 in _AppShell
//
// Providers consumed:
//   • journalProvider          — all entries for current user, newest first
//   • journalNotifierProvider  — .deleteEntry(id) called from _JournalCard dialog
//
// Navigation out:
//   • FAB → context.push('/journal/add') → AddJournalScreen
// =============================================================================
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../../core/theme.dart';
import '../models/journal_entry.dart';
import '../providers/journal_provider.dart';

class JournalScreen extends ConsumerWidget {
  const JournalScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncEntries = ref.watch(journalProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Journal')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/journal/add'),
        icon: const Icon(Icons.edit_outlined),
        label: const Text('New Entry'),
        backgroundColor: AppTheme.profitColor,
        foregroundColor: Colors.black,
      ),
      body: asyncEntries.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (entries) {
          if (entries.isEmpty) {
            return const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.book_outlined, size: 56, color: AppTheme.neutralColor),
                  SizedBox(height: 12),
                  Text(
                    'No journal entries yet.\nReflect on your trades.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppTheme.neutralColor),
                  ),
                ],
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: () => ref.refresh(journalProvider.future),
            child: ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: entries.length,
              separatorBuilder: (context, _) => const SizedBox(height: 10),
              itemBuilder: (context, i) => _JournalCard(entry: entries[i], ref: ref),
            ),
          );
        },
      ),
    );
  }
}

// _JournalCard: displays one journal entry with mood emoji, title, body preview,
// tags, and date. Delete icon opens a confirmation AlertDialog that calls
// journalNotifierProvider.deleteEntry().
class _JournalCard extends StatelessWidget {
  final JournalEntry entry;
  final WidgetRef ref;
  const _JournalCard({required this.entry, required this.ref});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (entry.mood != null)
                  Text(entry.mood!.emoji, style: const TextStyle(fontSize: 20)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    entry.title,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 15),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline,
                      color: AppTheme.neutralColor, size: 20),
                  onPressed: () => _confirmDelete(context),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              entry.body,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: AppTheme.neutralColor, height: 1.5),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                ...entry.tags.map((tag) => Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: AppTheme.profitColor.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          tag,
                          style: const TextStyle(
                              color: AppTheme.profitColor, fontSize: 11),
                        ),
                      ),
                    )),
                const Spacer(),
                Text(
                  DateFormat('MMM d, yyyy').format(entry.createdAt),
                  style: const TextStyle(
                      color: AppTheme.neutralColor, fontSize: 12),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _confirmDelete(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1C2230),
        title: const Text('Delete Entry?'),
        content: const Text('This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          ElevatedButton(
            style:
                ElevatedButton.styleFrom(backgroundColor: AppTheme.lossColor),
            onPressed: () {
              ref
                  .read(journalNotifierProvider.notifier)
                  .deleteEntry(entry.id);
              Navigator.pop(context);
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }
}
