// =============================================================================
// features/ticker_profile/widgets/add_ticker_note_sheet.dart
// =============================================================================
// Bottom sheet for adding a timestamped note to a ticker profile.
// Opened from: TickerProfileScreen Overview tab FAB
// Writes via: tickerProfileNotifierProvider.addNote()
// =============================================================================
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/ticker_profile_notifier.dart';

class AddTickerNoteSheet extends ConsumerStatefulWidget {
  final String symbol;
  const AddTickerNoteSheet({super.key, required this.symbol});

  @override
  ConsumerState<AddTickerNoteSheet> createState() => _AddTickerNoteSheetState();
}

class _AddTickerNoteSheetState extends ConsumerState<AddTickerNoteSheet> {
  final _bodyCtrl = TextEditingController();
  final _tagCtrl = TextEditingController();
  final List<String> _tags = [];
  bool _saving = false;

  @override
  void dispose() {
    _bodyCtrl.dispose();
    _tagCtrl.dispose();
    super.dispose();
  }

  void _addTag() {
    final tag = _tagCtrl.text.trim();
    if (tag.isNotEmpty && !_tags.contains(tag)) {
      setState(() {
        _tags.add(tag);
        _tagCtrl.clear();
      });
    }
  }

  Future<void> _save() async {
    if (_bodyCtrl.text.trim().isEmpty) return;
    setState(() => _saving = true);
    await ref
        .read(tickerProfileNotifierProvider.notifier)
        .addNote(widget.symbol, _bodyCtrl.text.trim(), List.of(_tags));
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 24,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Add Note — ${widget.symbol}',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 16),
          TextField(
            controller: _bodyCtrl,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: 'Observation',
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _tagCtrl,
                  decoration: const InputDecoration(labelText: 'Tag'),
                  onSubmitted: (_) => _addTag(),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.add),
                onPressed: _addTag,
              ),
            ],
          ),
          if (_tags.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Wrap(
                spacing: 6,
                children: _tags
                    .map((t) => Chip(
                          label: Text(t),
                          onDeleted: () => setState(() => _tags.remove(t)),
                        ))
                    .toList(),
              ),
            ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Save Note'),
          ),
        ],
      ),
    );
  }
}
