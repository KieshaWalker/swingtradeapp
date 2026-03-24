// =============================================================================
// features/ticker_profile/widgets/add_earnings_reaction_sheet.dart
// =============================================================================
// Bottom sheet for logging a post-earnings price reaction.
// Opened from: TickerProfileScreen Overview tab "Log Earnings" button
// Writes via: tickerProfileNotifierProvider.upsertEarningsReaction()
// =============================================================================
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/ticker_profile_models.dart';
import '../providers/ticker_profile_notifier.dart';

class AddEarningsReactionSheet extends ConsumerStatefulWidget {
  final String symbol;
  final TickerEarningsReaction? existing;

  const AddEarningsReactionSheet({
    super.key,
    required this.symbol,
    this.existing,
  });

  @override
  ConsumerState<AddEarningsReactionSheet> createState() =>
      _AddEarningsReactionSheetState();
}

class _AddEarningsReactionSheetState
    extends ConsumerState<AddEarningsReactionSheet> {
  final _periodCtrl = TextEditingController();
  final _epsActualCtrl = TextEditingController();
  final _epsEstCtrl = TextEditingController();
  final _revActualCtrl = TextEditingController();
  final _revEstCtrl = TextEditingController();
  final _priceBeforeCtrl = TextEditingController();
  final _priceAfterCtrl = TextEditingController();
  final _ivBeforeCtrl = TextEditingController();
  final _ivAfterCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();
  DateTime _earningsDate = DateTime.now();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null) {
      _earningsDate = e.earningsDate;
      _periodCtrl.text = e.fiscalPeriod ?? '';
      _epsActualCtrl.text = e.epsActual?.toString() ?? '';
      _epsEstCtrl.text = e.epsEstimate?.toString() ?? '';
      _revActualCtrl.text = e.revenueActual?.toString() ?? '';
      _revEstCtrl.text = e.revenueEstimate?.toString() ?? '';
      _priceBeforeCtrl.text = e.priceBefore?.toString() ?? '';
      _priceAfterCtrl.text = e.priceAfter?.toString() ?? '';
      _ivBeforeCtrl.text = e.ivRankBefore?.toString() ?? '';
      _ivAfterCtrl.text = e.ivRankAfter?.toString() ?? '';
      _notesCtrl.text = e.notes ?? '';
    }
  }

  @override
  void dispose() {
    for (final c in [
      _periodCtrl, _epsActualCtrl, _epsEstCtrl, _revActualCtrl,
      _revEstCtrl, _priceBeforeCtrl, _priceAfterCtrl,
      _ivBeforeCtrl, _ivAfterCtrl, _notesCtrl
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _earningsDate,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked != null) setState(() => _earningsDate = picked);
  }

  double? _parse(TextEditingController c) =>
      c.text.trim().isEmpty ? null : double.tryParse(c.text.trim());

  String? _direction() {
    final before = _parse(_priceBeforeCtrl);
    final after = _parse(_priceAfterCtrl);
    if (before == null || after == null) return null;
    final diff = after - before;
    if (diff.abs() < 0.01) return 'flat';
    return diff > 0 ? 'up' : 'down';
  }

  double? _movePct() {
    final before = _parse(_priceBeforeCtrl);
    final after = _parse(_priceAfterCtrl);
    if (before == null || after == null || before == 0) return null;
    return ((after - before) / before) * 100;
  }

  double? _epsSurprise() {
    final actual = _parse(_epsActualCtrl);
    final est = _parse(_epsEstCtrl);
    if (actual == null || est == null || est == 0) return null;
    return ((actual - est) / est.abs()) * 100;
  }

  Future<void> _save() async {
    setState(() => _saving = true);

    final reaction = TickerEarningsReaction(
      id: widget.existing?.id ?? '',
      userId: '',
      ticker: widget.symbol,
      earningsDate: _earningsDate,
      fiscalPeriod:
          _periodCtrl.text.trim().isEmpty ? null : _periodCtrl.text.trim(),
      epsActual: _parse(_epsActualCtrl),
      epsEstimate: _parse(_epsEstCtrl),
      epsSurprisePct: _epsSurprise(),
      revenueActual: _parse(_revActualCtrl),
      revenueEstimate: _parse(_revEstCtrl),
      priceBefore: _parse(_priceBeforeCtrl),
      priceAfter: _parse(_priceAfterCtrl),
      movePct: _movePct(),
      direction: _direction(),
      ivRankBefore: _parse(_ivBeforeCtrl),
      ivRankAfter: _parse(_ivAfterCtrl),
      notes: _notesCtrl.text.trim().isEmpty ? null : _notesCtrl.text.trim(),
    );

    await ref
        .read(tickerProfileNotifierProvider.notifier)
        .upsertEarningsReaction(widget.symbol, reaction);
    if (mounted) Navigator.pop(context);
  }

  Widget _row(Widget a, Widget b) => Row(
        children: [
          Expanded(child: a),
          const SizedBox(width: 12),
          Expanded(child: b),
        ],
      );

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
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
          Text(
              '${widget.existing != null ? 'Edit' : 'Log'} Earnings — ${widget.symbol}',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 16),
          InkWell(
            onTap: _pickDate,
            child: InputDecorator(
              decoration: const InputDecoration(labelText: 'Earnings Date'),
              child: Text(
                '${_earningsDate.year}-${_earningsDate.month.toString().padLeft(2, '0')}-${_earningsDate.day.toString().padLeft(2, '0')}',
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _periodCtrl,
            decoration: const InputDecoration(
                labelText: 'Fiscal Period', hintText: 'e.g. Q3 2025'),
          ),
          const SizedBox(height: 12),
          _row(
            TextField(
              controller: _epsActualCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true, signed: true),
              decoration: const InputDecoration(labelText: 'EPS Actual'),
            ),
            TextField(
              controller: _epsEstCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true, signed: true),
              decoration: const InputDecoration(labelText: 'EPS Est.'),
            ),
          ),
          const SizedBox(height: 12),
          _row(
            TextField(
              controller: _revActualCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration:
                  const InputDecoration(labelText: 'Revenue Actual'),
            ),
            TextField(
              controller: _revEstCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Revenue Est.'),
            ),
          ),
          const SizedBox(height: 12),
          _row(
            TextField(
              controller: _priceBeforeCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                  labelText: 'Price Before', prefixText: '\$'),
            ),
            TextField(
              controller: _priceAfterCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                  labelText: 'Price After', prefixText: '\$'),
            ),
          ),
          const SizedBox(height: 12),
          _row(
            TextField(
              controller: _ivBeforeCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration:
                  const InputDecoration(labelText: 'IV Rank Before'),
            ),
            TextField(
              controller: _ivAfterCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration:
                  const InputDecoration(labelText: 'IV Rank After'),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _notesCtrl,
            maxLines: 2,
            decoration: const InputDecoration(labelText: 'Notes (optional)'),
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
                : const Text('Save'),
          ),
        ],
      ),
    );
  }
}
