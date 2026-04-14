// =============================================================================
// features/journal/screens/add_journal_screen.dart — New / edit journal entry
// =============================================================================
// Widgets defined here:
//   • AddJournalScreen (ConsumerStatefulWidget) — form for adding or editing an
//     entry; pass [initialEntry] to open in edit mode.
//
// Route: '/journal/add' (child of /journal in router.dart)
//   Add:  context.push('/journal/add')
//   Edit: context.push('/journal/add', extra: existingEntry)
//
// Providers consumed:
//   • currentUserProvider          — attaches user_id on new entries
//   • journalNotifierProvider      — .addEntry() / .updateEntry()
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
  final JournalEntry? initialEntry;
  const AddJournalScreen({super.key, this.initialEntry});

  @override
  ConsumerState<AddJournalScreen> createState() => _AddJournalScreenState();
}

class _AddJournalScreenState extends ConsumerState<AddJournalScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _titleCtrl;
  late final TextEditingController _bodyCtrl;
  final _tagCtrl = TextEditingController();

  TradeMood? _mood;
  late List<String> _tags;

  bool get _isEditing => widget.initialEntry != null;

  @override
  void initState() {
    super.initState();
    final e = widget.initialEntry;
    _titleCtrl = TextEditingController(text: e?.title ?? '');
    _bodyCtrl  = TextEditingController(text: e?.body ?? '');
    _mood = e?.mood;
    _tags = List<String>.from(e?.tags ?? []);
  }

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
    final notifier = ref.read(journalNotifierProvider.notifier);

    if (_isEditing) {
      final updated = JournalEntry(
        id:        widget.initialEntry!.id,
        userId:    widget.initialEntry!.userId,
        tradeId:   widget.initialEntry!.tradeId,
        title:     _titleCtrl.text.trim(),
        body:      _bodyCtrl.text.trim(),
        mood:      _mood,
        tags:      _tags,
        createdAt: widget.initialEntry!.createdAt,
      );
      await notifier.updateEntry(updated);
    } else {
      final user = ref.read(currentUserProvider);
      if (user == null) return;
      final entry = JournalEntry(
        id:        const Uuid().v4(),
        userId:    user.id,
        title:     _titleCtrl.text.trim(),
        body:      _bodyCtrl.text.trim(),
        mood:      _mood,
        tags:      _tags,
        createdAt: DateTime.now(),
      );
      await notifier.addEntry(entry);
    }

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
      appBar: AppBar(
        title: Text(_isEditing ? 'Edit Entry' : 'New Journal Entry'),
      ),
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
                    child: Text(_isEditing ? 'Save Changes' : 'Save Entry'),
                  ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}
