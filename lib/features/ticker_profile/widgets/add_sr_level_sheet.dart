// =============================================================================
// features/ticker_profile/widgets/add_sr_level_sheet.dart
// =============================================================================
// Bottom sheet for adding a support or resistance price level.
// Opened from: TickerProfileScreen Levels tab FAB
// Writes via: tickerProfileNotifierProvider.addSRLevel()
// =============================================================================
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/ticker_profile_models.dart';
import '../providers/ticker_profile_notifier.dart';

class AddSRLevelSheet extends ConsumerStatefulWidget {
  final String symbol;
  const AddSRLevelSheet({super.key, required this.symbol});

  @override
  ConsumerState<AddSRLevelSheet> createState() => _AddSRLevelSheetState();
}

class _AddSRLevelSheetState extends ConsumerState<AddSRLevelSheet> {
  final _priceCtrl = TextEditingController();
  final _labelCtrl = TextEditingController();
  SRLevelType _levelType = SRLevelType.support;
  SRTimeframe? _timeframe = SRTimeframe.daily;
  bool _saving = false;

  @override
  void dispose() {
    _priceCtrl.dispose();
    _labelCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final price = double.tryParse(_priceCtrl.text.trim());
    if (price == null) return;
    setState(() => _saving = true);

    final level = SupportResistanceLevel(
      id: '',
      userId: '',
      ticker: widget.symbol,
      levelType: _levelType,
      price: price,
      label: _labelCtrl.text.trim().isEmpty ? null : _labelCtrl.text.trim(),
      timeframe: _timeframe,
      notedAt: DateTime.now(),
    );

    await ref
        .read(tickerProfileNotifierProvider.notifier)
        .addSRLevel(widget.symbol, level);
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
          Text('Add S/R Level — ${widget.symbol}',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 16),
          SegmentedButton<SRLevelType>(
            segments: const [
              ButtonSegment(
                  value: SRLevelType.support, label: Text('Support')),
              ButtonSegment(
                  value: SRLevelType.resistance, label: Text('Resistance')),
            ],
            selected: {_levelType},
            onSelectionChanged: (s) => setState(() => _levelType = s.first),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _priceCtrl,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Price',
              prefixText: '\$',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _labelCtrl,
            decoration: const InputDecoration(
              labelText: 'Label (optional)',
              hintText: 'e.g. 200MA, Aug swing low',
            ),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<SRTimeframe>(
            initialValue: _timeframe,
            decoration: const InputDecoration(labelText: 'Timeframe'),
            items: SRTimeframe.values
                .map((t) => DropdownMenuItem(
                      value: t,
                      child: Text(t.label),
                    ))
                .toList(),
            onChanged: (v) => setState(() => _timeframe = v),
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
                : const Text('Add Level'),
          ),
        ],
      ),
    );
  }
}
