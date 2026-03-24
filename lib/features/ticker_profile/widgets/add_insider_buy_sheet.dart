// =============================================================================
// features/ticker_profile/widgets/add_insider_buy_sheet.dart
// =============================================================================
// Bottom sheet for logging a Form 4 insider buy event.
// Opened from: TickerProfileScreen Overview tab "Log Buy" button
// Writes via: tickerProfileNotifierProvider.addInsiderBuy()
// =============================================================================
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/ticker_profile_models.dart';
import '../providers/ticker_profile_notifier.dart';

class AddInsiderBuySheet extends ConsumerStatefulWidget {
  final String symbol;
  const AddInsiderBuySheet({super.key, required this.symbol});

  @override
  ConsumerState<AddInsiderBuySheet> createState() =>
      _AddInsiderBuySheetState();
}

class _AddInsiderBuySheetState extends ConsumerState<AddInsiderBuySheet> {
  final _nameCtrl = TextEditingController();
  final _titleCtrl = TextEditingController();
  final _sharesCtrl = TextEditingController();
  final _priceCtrl = TextEditingController();
  final _accessionCtrl = TextEditingController();
  DateTime _filedAt = DateTime.now();
  InsiderTransactionType _txType = InsiderTransactionType.purchase;
  bool _saving = false;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _titleCtrl.dispose();
    _sharesCtrl.dispose();
    _priceCtrl.dispose();
    _accessionCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _filedAt,
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
    );
    if (picked != null) setState(() => _filedAt = picked);
  }

  Future<void> _save() async {
    final shares = int.tryParse(_sharesCtrl.text.trim());
    if (_nameCtrl.text.trim().isEmpty || shares == null) return;
    setState(() => _saving = true);

    final price = double.tryParse(_priceCtrl.text.trim());
    final total = price != null ? price * shares : null;

    final buy = TickerInsiderBuy(
      id: '',
      userId: '',
      ticker: widget.symbol,
      insiderName: _nameCtrl.text.trim(),
      insiderTitle:
          _titleCtrl.text.trim().isEmpty ? null : _titleCtrl.text.trim(),
      shares: shares,
      pricePerShare: price,
      totalValue: total,
      filedAt: _filedAt,
      accessionNo: _accessionCtrl.text.trim().isEmpty
          ? null
          : _accessionCtrl.text.trim(),
      transactionType: _txType,
    );

    await ref
        .read(tickerProfileNotifierProvider.notifier)
        .addInsiderBuy(widget.symbol, buy);
    if (mounted) Navigator.pop(context);
  }

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
          Text('Log Insider Buy — ${widget.symbol}',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 16),
          TextField(
            controller: _nameCtrl,
            decoration:
                const InputDecoration(labelText: 'Insider Name'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _titleCtrl,
            decoration: const InputDecoration(
                labelText: 'Title (optional)', hintText: 'e.g. CEO, Director'),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _sharesCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Shares'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _priceCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Price/sh',
                    prefixText: '\$',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<InsiderTransactionType>(
            initialValue: _txType,
            decoration: const InputDecoration(labelText: 'Transaction Type'),
            items: InsiderTransactionType.values
                .map((t) => DropdownMenuItem(
                      value: t,
                      child: Text(t.name[0].toUpperCase() + t.name.substring(1)),
                    ))
                .toList(),
            onChanged: (v) => setState(() => _txType = v!),
          ),
          const SizedBox(height: 12),
          InkWell(
            onTap: _pickDate,
            child: InputDecorator(
              decoration: const InputDecoration(labelText: 'Filed Date'),
              child: Text(
                '${_filedAt.year}-${_filedAt.month.toString().padLeft(2, '0')}-${_filedAt.day.toString().padLeft(2, '0')}',
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _accessionCtrl,
            decoration: const InputDecoration(
              labelText: 'Accession # (optional)',
              hintText: 'SEC EDGAR accession number',
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
                : const Text('Log Buy'),
          ),
        ],
      ),
    );
  }
}
