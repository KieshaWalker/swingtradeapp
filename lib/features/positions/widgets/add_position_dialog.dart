// =============================================================================
// features/positions/widgets/add_position_dialog.dart
// =============================================================================
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../../../core/theme.dart';
import '../../../services/schwab/schwab_models.dart';
import '../../../services/schwab/schwab_providers.dart';
import '../models/position_models.dart';

// ── Mutable draft for a leg inside the dialog ─────────────────────────────────

class _LegDraft {
  final String draftId = const Uuid().v4();
  String? existingId;
  LegType type;
  String ticker;
  double? strike;
  String? expiry;
  int? quantity;
  double? entryPrice;

  _LegDraft({
    this.existingId,
    this.type = LegType.call,
    this.ticker = '',
    this.strike,
    this.expiry,
    this.quantity,
    this.entryPrice,
  });

  factory _LegDraft.fromLeg(PositionLeg l) => _LegDraft(
        existingId: l.id,
        type: l.type,
        ticker: l.ticker,
        strike: l.strike,
        expiry: l.expiry,
        quantity: l.quantity,
        entryPrice: l.entryPrice,
      );

  bool get isValid {
    if (ticker.trim().isEmpty || quantity == null || quantity == 0) return false;
    if (type == LegType.underlying) return true;
    return strike != null && expiry != null;
  }

  PositionLeg toLeg() {
    final id = existingId ?? const Uuid().v4();
    if (type == LegType.underlying) {
      return PositionLeg(
        id: id,
        type: LegType.underlying,
        ticker: ticker.toUpperCase().trim(),
        quantity: quantity!,
        entryPrice: entryPrice,
      );
    }
    return PositionLeg(
      id: id,
      type: type,
      ticker: ticker.toUpperCase().trim(),
      strike: strike,
      expiry: expiry,
      quantity: quantity!,
      entryPrice: entryPrice,
    );
  }
}

// ── Dialog entry point ────────────────────────────────────────────────────────

Future<void> showAddPositionDialog(
  BuildContext context, {
  Position? existing,
  required void Function(Position) onSave,
}) {
  return showDialog(
    context: context,
    builder: (_) => _AddPositionDialog(existing: existing, onSave: onSave),
  );
}

// ── Dialog widget ─────────────────────────────────────────────────────────────

class _AddPositionDialog extends StatefulWidget {
  final Position? existing;
  final void Function(Position) onSave;

  const _AddPositionDialog({this.existing, required this.onSave});

  @override
  State<_AddPositionDialog> createState() => _AddPositionDialogState();
}

class _AddPositionDialogState extends State<_AddPositionDialog> {
  late final TextEditingController _nameCtrl;
  late List<_LegDraft> _legs;
  String? _error;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.existing?.name ?? '');
    _legs = widget.existing?.legs.map(_LegDraft.fromLeg).toList() ?? [];
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  void _addLeg(LegType type) {
    setState(() => _legs.add(_LegDraft(type: type)));
  }

  void _removeLeg(int i) {
    setState(() => _legs.removeAt(i));
  }

  void _save() {
    setState(() => _error = null);
    if (_nameCtrl.text.trim().isEmpty) {
      setState(() => _error = 'Position name is required.');
      return;
    }
    if (_legs.isEmpty) {
      setState(() => _error = 'Add at least one leg.');
      return;
    }
    for (final d in _legs) {
      if (!d.isValid) {
        setState(() =>
            _error = 'All legs must have a ticker, quantity, and (for options) strike & expiry.');
        return;
      }
    }
    final position = widget.existing != null
        ? widget.existing!.copyWith(
            name: _nameCtrl.text.trim(),
            legs: _legs.map((d) => d.toLeg()).toList(),
          )
        : Position.create(
            name: _nameCtrl.text.trim(),
            legs: _legs.map((d) => d.toLeg()).toList(),
          );
    widget.onSave(position);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppTheme.elevatedColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 40),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.82,
          maxWidth: 560,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Title bar
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 0),
              child: Row(
                children: [
                  Text(
                    widget.existing == null ? 'Add Position' : 'Edit Position',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w700),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white54),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(color: AppTheme.borderColor),
            // Scrollable body
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Name
                    TextField(
                      controller: _nameCtrl,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        labelText: 'Position name',
                        hintText: 'e.g. Short strangle SPY',
                      ),
                    ),
                    const SizedBox(height: 16),
                    // Legs
                    if (_legs.isNotEmpty) ...[
                      const Text('Legs',
                          style: TextStyle(
                              color: AppTheme.neutralColor,
                              fontSize: 12,
                              fontWeight: FontWeight.w600)),
                      const SizedBox(height: 8),
                      for (int i = 0; i < _legs.length; i++)
                        _LegEditor(
                          key: ValueKey(_legs[i].draftId),
                          draft: _legs[i],
                          onRemove: () => _removeLeg(i),
                          onChanged: () => setState(() {}),
                        ),
                    ],
                    // Add leg buttons
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        _addLegButton(
                          Icons.add_circle_outline,
                          'Option leg',
                          () => _addLeg(LegType.call),
                        ),
                        const SizedBox(width: 8),
                        _addLegButton(
                          Icons.add_circle_outline,
                          'Underlying leg',
                          () => _addLeg(LegType.underlying),
                        ),
                      ],
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 10),
                      Text(_error!,
                          style: const TextStyle(
                              color: AppTheme.lossColor, fontSize: 12)),
                    ],
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ),
            const Divider(color: AppTheme.borderColor),
            // Actions
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _save,
                    child: Text(widget.existing == null ? 'Add' : 'Save'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _addLegButton(IconData icon, String label, VoidCallback onPressed) {
    return OutlinedButton.icon(
      icon: Icon(icon, size: 16),
      label: Text(label, style: const TextStyle(fontSize: 12)),
      style: OutlinedButton.styleFrom(
        foregroundColor: AppTheme.profitColor,
        side: const BorderSide(color: AppTheme.profitColor),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      onPressed: onPressed,
    );
  }
}

// ── Per-leg editor ────────────────────────────────────────────────────────────

class _LegEditor extends ConsumerStatefulWidget {
  final _LegDraft draft;
  final VoidCallback onRemove;
  final VoidCallback onChanged;

  const _LegEditor({
    required super.key,
    required this.draft,
    required this.onRemove,
    required this.onChanged,
  });

  @override
  ConsumerState<_LegEditor> createState() => _LegEditorState();
}

class _LegEditorState extends ConsumerState<_LegEditor> {
  late final TextEditingController _tickerCtrl;
  late final TextEditingController _strikeCtrl;
  late final TextEditingController _qtyCtrl;
  late final TextEditingController _entryCtrl;

  // Chain-aware entry: once a chain is looked up for this ticker, strike and
  // expiry switch from free-text to dropdowns sourced from real contracts --
  // closes the gap where a typo'd strike/expiry silently produced a leg with
  // no market data. Falls back to the original manual fields if lookup fails
  // or hasn't been triggered (e.g. no Schwab connection), so the dialog
  // never gets blocked by the live chain being unavailable.
  String? _chainTicker;
  OptionsChainParams? _chainParams;

  @override
  void initState() {
    super.initState();
    _tickerCtrl = TextEditingController(text: widget.draft.ticker);
    _strikeCtrl = TextEditingController(text: widget.draft.strike?.toString() ?? '');
    _qtyCtrl = TextEditingController(text: widget.draft.quantity?.toString() ?? '');
    _entryCtrl = TextEditingController(text: widget.draft.entryPrice?.toString() ?? '');
  }

  @override
  void dispose() {
    _tickerCtrl.dispose();
    _strikeCtrl.dispose();
    _qtyCtrl.dispose();
    _entryCtrl.dispose();
    super.dispose();
  }

  void _lookUpChain() {
    final ticker = _tickerCtrl.text.trim().toUpperCase();
    if (ticker.isEmpty) return;
    setState(() {
      _chainTicker = ticker;
      _chainParams = OptionsChainParams(
        symbol: ticker, contractType: 'ALL', strikeCount: 50,
      );
    });
  }

  void _onExpirySelected(String expiry, SchwabOptionsChain chain) {
    setState(() {
      widget.draft.expiry = expiry;
      // Strike may no longer be valid for the newly-selected expiry — clear
      // it rather than silently keep a strike from a different expiration.
      widget.draft.strike = null;
      _strikeCtrl.text = '';
    });
    widget.onChanged();
  }

  void _onStrikeSelected(SchwabOptionContract contract) {
    setState(() {
      widget.draft.strike = contract.strikePrice;
      _strikeCtrl.text = contract.strikePrice.toString();
      // Suggest the live mark as entry price -- only when the user hasn't
      // already typed one, so this never clobbers a real fill price.
      if (widget.draft.entryPrice == null && _entryCtrl.text.trim().isEmpty) {
        widget.draft.entryPrice = contract.markPrice;
        _entryCtrl.text = contract.markPrice.toStringAsFixed(2);
      }
    });
    widget.onChanged();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final initial = widget.draft.expiry != null
        ? DateTime.tryParse(widget.draft.expiry!) ?? now
        : now;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial.isBefore(now) ? now : initial,
      firstDate: now,
      lastDate: DateTime(now.year + 3),
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: const ColorScheme.dark(
            primary: AppTheme.profitColor,
            onPrimary: Colors.black,
            surface: AppTheme.elevatedColor,
          ),
        ),
        child: child!,
      ),
    );
    if (picked == null) return;
    final iso =
        '${picked.year.toString().padLeft(4, '0')}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
    setState(() => widget.draft.expiry = iso);
    widget.onChanged();
  }

  Widget _manualStrikeExpiryRow(_LegDraft draft) => Row(
        children: [
          Expanded(
            child: TextField(
              controller: _strikeCtrl,
              style: const TextStyle(color: Colors.white),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Strike',
                hintText: '95',
                isDense: true,
              ),
              onChanged: (v) {
                draft.strike = double.tryParse(v);
                widget.onChanged();
              },
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: GestureDetector(
              onTap: _pickDate,
              child: InputDecorator(
                decoration: const InputDecoration(
                  labelText: 'Expiry',
                  isDense: true,
                  suffixIcon: Icon(Icons.calendar_today_outlined,
                      size: 16, color: AppTheme.neutralColor),
                ),
                child: Text(
                  draft.expiry ?? 'Pick date',
                  style: TextStyle(
                    color: draft.expiry != null ? Colors.white : Colors.white38,
                    fontSize: 14,
                  ),
                ),
              ),
            ),
          ),
        ],
      );

  Widget _chainStrikeExpiryRow(_LegDraft draft, OptionsChainParams params) {
    final chainAsync = ref.watch(schwabOptionsChainProvider(params));
    return chainAsync.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Row(children: [
          SizedBox(
              width: 14, height: 14,
              child: CircularProgressIndicator(strokeWidth: 1.5)),
          SizedBox(width: 8),
          Text('Loading chain…',
              style: TextStyle(color: AppTheme.neutralColor, fontSize: 12)),
        ]),
      ),
      error: (e, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Chain lookup failed — using manual entry',
              style: const TextStyle(color: AppTheme.lossColor, fontSize: 11)),
          const SizedBox(height: 8),
          _manualStrikeExpiryRow(draft),
        ],
      ),
      data: (chain) {
        if (chain == null || chain.expirations.isEmpty) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('No chain data — using manual entry',
                  style: TextStyle(color: AppTheme.lossColor, fontSize: 11)),
              const SizedBox(height: 8),
              _manualStrikeExpiryRow(draft),
            ],
          );
        }

        final expiryDates = chain.expirations.map((e) => e.expirationDate).toList();
        final selectedExpiry =
            expiryDates.contains(draft.expiry) ? draft.expiry : null;
        final expiration = selectedExpiry == null
            ? null
            : chain.expirations.firstWhere((e) => e.expirationDate == selectedExpiry);
        final contracts = expiration == null
            ? const <SchwabOptionContract>[]
            : (draft.type == LegType.put ? expiration.puts : expiration.calls);
        final sortedContracts = [...contracts]
          ..sort((a, b) => a.strikePrice.compareTo(b.strikePrice));
        final selectedStrike = sortedContracts
            .where((c) => c.strikePrice == draft.strike)
            .firstOrNull;

        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: DropdownButtonFormField<double>(
                initialValue: selectedStrike?.strikePrice,
                isExpanded: true,
                dropdownColor: AppTheme.elevatedColor,
                style: const TextStyle(color: Colors.white, fontSize: 13),
                decoration: const InputDecoration(labelText: 'Strike', isDense: true),
                hint: const Text('Select', style: TextStyle(color: Colors.white38)),
                items: sortedContracts
                    .map((c) => DropdownMenuItem(
                          value: c.strikePrice,
                          child: Text(
                              '\$${c.strikePrice.toStringAsFixed(c.strikePrice % 1 == 0 ? 0 : 1)}  '
                              '(mark \$${c.markPrice.toStringAsFixed(2)})'),
                        ))
                    .toList(),
                onChanged: expiration == null
                    ? null
                    : (v) {
                        final c = sortedContracts.where((c) => c.strikePrice == v).firstOrNull;
                        if (c != null) _onStrikeSelected(c);
                      },
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: DropdownButtonFormField<String>(
                initialValue: selectedExpiry,
                isExpanded: true,
                dropdownColor: AppTheme.elevatedColor,
                style: const TextStyle(color: Colors.white, fontSize: 13),
                decoration: const InputDecoration(labelText: 'Expiry', isDense: true),
                hint: const Text('Select', style: TextStyle(color: Colors.white38)),
                items: expiryDates
                    .map((d) => DropdownMenuItem(value: d, child: Text(d)))
                    .toList(),
                onChanged: (v) {
                  if (v != null) _onExpirySelected(v, chain);
                },
              ),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final draft = widget.draft;
    final isOption = draft.type != LegType.underlying;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.cardColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header row: type toggle + remove
          Row(
            children: [
              // Leg type selector
              if (draft.type != LegType.underlying) ...[
                _typeChip('Call', LegType.call, draft.type),
                const SizedBox(width: 6),
                _typeChip('Put', LegType.put, draft.type),
                const SizedBox(width: 6),
                _typeChip('Underlying', LegType.underlying, draft.type),
              ] else ...[
                _typeChip('Underlying', LegType.underlying, draft.type),
                const SizedBox(width: 6),
                _typeChip('Option', LegType.call, draft.type),
              ],
              const Spacer(),
              GestureDetector(
                onTap: widget.onRemove,
                child: const Icon(Icons.remove_circle_outline,
                    size: 18, color: AppTheme.lossColor),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // Ticker + Qty row
          Row(
            children: [
              Expanded(
                flex: 2,
                child: TextField(
                  controller: _tickerCtrl,
                  style: const TextStyle(color: Colors.white),
                  textCapitalization: TextCapitalization.characters,
                  decoration: InputDecoration(
                    labelText: 'Ticker',
                    hintText: 'SPY',
                    isDense: true,
                    suffixIcon: isOption
                        ? IconButton(
                            icon: const Icon(Icons.search_rounded,
                                size: 18, color: AppTheme.neutralColor),
                            tooltip: 'Look up live chain',
                            onPressed: _lookUpChain,
                          )
                        : null,
                  ),
                  onSubmitted: (_) => isOption ? _lookUpChain() : null,
                  onChanged: (v) {
                    draft.ticker = v;
                    // A ticker edit invalidates any chain looked up for the
                    // old symbol -- fall back to manual fields until the
                    // user looks up the new one.
                    if (_chainTicker != null && v.trim().toUpperCase() != _chainTicker) {
                      _chainTicker = null;
                      _chainParams = null;
                    }
                    widget.onChanged();
                  },
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: TextField(
                  controller: _qtyCtrl,
                  style: const TextStyle(color: Colors.white),
                  keyboardType:
                      const TextInputType.numberWithOptions(signed: true),
                  decoration: const InputDecoration(
                    labelText: 'Qty',
                    hintText: '-10 or +8',
                    isDense: true,
                  ),
                  onChanged: (v) {
                    draft.quantity = int.tryParse(v);
                    widget.onChanged();
                  },
                ),
              ),
            ],
          ),
          // Strike + Expiry row (options only) -- chain-aware dropdowns once
          // a chain has been looked up, manual fields otherwise.
          if (isOption) ...[
            const SizedBox(height: 10),
            _chainParams == null
                ? _manualStrikeExpiryRow(draft)
                : _chainStrikeExpiryRow(draft, _chainParams!),
          ],
          // Entry price row
          const SizedBox(height: 10),
          TextField(
            controller: _entryCtrl,
            style: const TextStyle(color: Colors.white),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Entry price',
              hintText: 'Filled price (optional)',
              isDense: true,
            ),
            onChanged: (v) {
              draft.entryPrice = double.tryParse(v);
              widget.onChanged();
            },
          ),
        ],
      ),
    );
  }

  Widget _typeChip(String label, LegType value, LegType current) {
    final selected = value == current;
    return GestureDetector(
      onTap: () {
        setState(() => widget.draft.type = value);
        widget.onChanged();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: selected
              ? AppTheme.profitColor.withValues(alpha: 0.18)
              : AppTheme.elevatedColor,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color:
                selected ? AppTheme.profitColor : AppTheme.borderColor,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? AppTheme.profitColor : Colors.white54,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
