// =============================================================================
// features/journal/screens/add_journal_screen.dart — New journal entry form
// =============================================================================
// Widgets defined here:
//   • AddJournalScreen (ConsumerStatefulWidget) — full form for a new entry;
//     navigated to from JournalScreen FAB via context.push('/journal/add')
//
// Route: '/journal/add' (child of /journal in router.dart)
//
// Providers consumed:
//   • currentUserProvider          — attaches user_id to new JournalEntry
//   • journalNotifierProvider      — .addEntry(entry) inserts to Supabase,
//                                    then invalidates journalProvider
//
// Form sections:
//   1. Mood picker — 5 animated emoji buttons (TradeMood enum);
//      selected mood highlighted with profitColor ring
//   2. Title text field (required)
//   3. Body textarea, 8 lines (required)
//   4. Tag input — text field + add button; added tags shown as dismissible Chips
//
// On success: context.pop() back to JournalScreen
// =============================================================================
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';
import '../../../core/theme.dart';
import '../../auth/providers/auth_provider.dart';
import '../models/journal_entry.dart';
import '../providers/journal_provider.dart';

class AddJournalScreen extends ConsumerStatefulWidget {
  const AddJournalScreen({super.key});

  @override
  ConsumerState<AddJournalScreen> createState() => _AddJournalScreenState();
}

class _AddJournalScreenState extends ConsumerState<AddJournalScreen> {
  final _formKey = GlobalKey<FormState>();
  final _titleCtrl = TextEditingController();
  final _bodyCtrl = TextEditingController();
  final _tagCtrl = TextEditingController();

  TradeMood? _mood;
  final List<String> _tags = [];

  @override
  void dispose() {
    _titleCtrl.dispose();
    _bodyCtrl.dispose();
    _tagCtrl.dispose();
    super.dispose();
  }

  void _addTag() {
    final tag = _tagCtrl.text.trim();
    if (tag.isEmpty || _tags.contains(tag)) return;
    setState(() {
      _tags.add(tag);
      _tagCtrl.clear();
    });
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final user = ref.read(currentUserProvider);
    if (user == null) return;

    final entry = JournalEntry(
      id: const Uuid().v4(),
      userId: user.id,
      title: _titleCtrl.text.trim(),
      body: _bodyCtrl.text.trim(),
      mood: _mood,
      tags: _tags,
      createdAt: DateTime.now(),
    );

    await ref.read(journalNotifierProvider.notifier).addEntry(entry);

    if (mounted) {
      final state = ref.read(journalNotifierProvider);
      if (state.hasError) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: ${state.error}'),
            backgroundColor: AppTheme.lossColor,
          ),
        );
      } else {
        context.pop();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isLoading = ref.watch(journalNotifierProvider).isLoading;

    return Scaffold(
      appBar: AppBar(title: const Text('New Journal Entry')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Mood picker
            const Text(
              'How are you feeling about this trade?',
              style: TextStyle(color: AppTheme.neutralColor),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: TradeMood.values.map((m) {
                final selected = _mood == m;
                return GestureDetector(
                  onTap: () => setState(() => _mood = m),
                  child: Column(
                    children: [
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: selected
                              ? AppTheme.profitColor.withValues(alpha: 0.2)
                              : AppTheme.cardColor,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: selected
                                ? AppTheme.profitColor
                                : AppTheme.borderColor,
                          ),
                        ),
                        child: Text(m.emoji,
                            style: const TextStyle(fontSize: 22)),
                      ),
                      const SizedBox(height: 4),
                      Text(m.label,
                          style: TextStyle(
                              fontSize: 10,
                              color: selected
                                  ? AppTheme.profitColor
                                  : AppTheme.neutralColor)),
                    ],
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 24),

            TextFormField(
              controller: _titleCtrl,
              decoration: const InputDecoration(labelText: 'Title *'),
              validator: (v) => v == null || v.isEmpty ? 'Required' : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _bodyCtrl,
              maxLines: 8,
              decoration: const InputDecoration(
                labelText: 'Entry *',
                alignLabelWithHint: true,
                hintText:
                    'What happened? What did you do right/wrong? What will you improve?',
              ),
              validator: (v) => v == null || v.isEmpty ? 'Required' : null,
            ),
            const SizedBox(height: 16),

            // Tags
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _tagCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Add Tag',
                      hintText: 'e.g. FOMO, discipline, scalp',
                    ),
                    onFieldSubmitted: (_) => _addTag(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: _addTag,
                  icon: const Icon(Icons.add),
                  style: IconButton.styleFrom(
                    backgroundColor: AppTheme.profitColor,
                    foregroundColor: Colors.black,
                  ),
                ),
              ],
            ),
            if (_tags.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                children: _tags
                    .map((t) => Chip(
                          label: Text(t),
                          deleteIcon: const Icon(Icons.close, size: 14),
                          onDeleted: () => setState(() => _tags.remove(t)),
                        ))
                    .toList(),
              ),
            ],
            const SizedBox(height: 32),

            isLoading
                ? const Center(child: CircularProgressIndicator())
                : ElevatedButton(
                    onPressed: _submit,
                    child: const Text('Save Entry'),
                  ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}
