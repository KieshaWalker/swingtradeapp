// =============================================================================
// features/trades/screens/add_trade_screen.dart — Log a new trade
// =============================================================================
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';
import '../../../core/theme.dart';
import '../../../services/fmp/fmp_providers.dart';
import '../../auth/providers/auth_provider.dart';
import '../models/trade.dart';
import '../providers/trades_provider.dart';

class AddTradeScreen extends ConsumerStatefulWidget {
  const AddTradeScreen({super.key});

  @override
  ConsumerState<AddTradeScreen> createState() => _AddTradeScreenState();
}

class _AddTradeScreenState extends ConsumerState<AddTradeScreen> {
  final _formKey = GlobalKey<FormState>();

  final _tickerCtrl        = TextEditingController();
  final _strikeCtrl        = TextEditingController();
  final _contractsCtrl     = TextEditingController(text: '1');
  final _entryCtrl         = TextEditingController();
  final _ivRankCtrl        = TextEditingController();
  final _deltaCtrl         = TextEditingController();
  final _notesCtrl         = TextEditingController();
  final _priceHighCtrl     = TextEditingController();
  final _priceLowCtrl      = TextEditingController();
  final _impliedVolEntryCtrl = TextEditingController();
  final _intradaySupportCtrl = TextEditingController();
  final _intradayResistanceCtrl = TextEditingController();
  final _breakoutCtrl      = TextEditingController();
  final _breakdownCtrl     = TextEditingController();
  final _maxLossCtrl       = TextEditingController();
  final _timeOfEntryCtrl   = TextEditingController();


  OptionType _optionType   = OptionType.call;
  TradeStrategy _strategy  = TradeStrategy.longCall;
  EntryPointType? _entryPointType;
  DateTime _expiration     = DateTime.now().add(const Duration(days: 30));

  @override
  void dispose() {
    _tickerCtrl.dispose();
    _strikeCtrl.dispose();
    _contractsCtrl.dispose();
    _entryCtrl.dispose();
    _ivRankCtrl.dispose();
    _deltaCtrl.dispose();
    _notesCtrl.dispose();
    _priceHighCtrl.dispose();
    _priceLowCtrl.dispose();
    _impliedVolEntryCtrl.dispose();
    _intradaySupportCtrl.dispose();
    _intradayResistanceCtrl.dispose();
    _breakoutCtrl.dispose();
    _breakdownCtrl.dispose();
    _maxLossCtrl.dispose();
    _timeOfEntryCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickExpiration() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _expiration,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 730)),
    );
    if (picked != null) setState(() => _expiration = picked);
  }

  int get _dteAtEntry => _expiration.difference(DateTime.now()).inDays;

  double? _parse(TextEditingController c) =>
      c.text.isNotEmpty ? double.tryParse(c.text) : null;

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final user = ref.read(currentUserProvider);
    if (user == null) return;

    final trade = Trade(
      id: const Uuid().v4(),
      userId: user.id,
      ticker: _tickerCtrl.text.trim().toUpperCase(),
      optionType: _optionType,
      strategy: _strategy,
      strike: double.parse(_strikeCtrl.text),
      expiration: _expiration,
      dteAtEntry: _dteAtEntry,
      contracts: int.parse(_contractsCtrl.text),
      entryPrice: double.parse(_entryCtrl.text),
      status: TradeStatus.open,
      ivRank: _parse(_ivRankCtrl),
      delta: _parse(_deltaCtrl),
      notes: _notesCtrl.text.isNotEmpty ? _notesCtrl.text : null,
      openedAt: DateTime.now(),
      priceRangeHigh: _parse(_priceHighCtrl),
      priceRangeLow: _parse(_priceLowCtrl),
      impliedVolEntry: _parse(_impliedVolEntryCtrl),
      intradaySupport: _parse(_intradaySupportCtrl),
      intradayResistance: _parse(_intradayResistanceCtrl),
      dailyBreakoutLevel: _parse(_breakoutCtrl),
      dailyBreakdownLevel: _parse(_breakdownCtrl),
      entryPointType: _entryPointType,
      maxLoss: _parse(_maxLossCtrl),
      timeOfEntry: _timeOfEntryCtrl.text.isNotEmpty ? _timeOfEntryCtrl.text : null,
    );

    await ref.read(tradesNotifierProvider.notifier).addTrade(trade);

    if (mounted) {
      final st = ref.read(tradesNotifierProvider);
      if (st.hasError) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: ${st.error}'),
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
    final isLoading = ref.watch(tradesNotifierProvider).isLoading;

    return Scaffold(
      appBar: AppBar(title: const Text('Log Trade')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // ── Ticker ────────────────────────────────────────────────────────
            _TickerAutocomplete(controller: _tickerCtrl, ref: ref),
            const SizedBox(height: 16),

            // ── Call / Put ────────────────────────────────────────────────────
            _SectionLabel('Option Type'),
            Row(
              children: OptionType.values.map((type) {
                final selected = _optionType == type;
                final color = type == OptionType.call
                    ? AppTheme.profitColor
                    : AppTheme.lossColor;
                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: GestureDetector(
                      onTap: () => setState(() => _optionType = type),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        decoration: BoxDecoration(
                          color: selected
                              ? color.withValues(alpha: 0.2)
                              : AppTheme.cardColor,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: selected ? color : AppTheme.borderColor,
                          ),
                        ),
                        child: Text(
                          type.name.toUpperCase(),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: selected ? color : AppTheme.neutralColor,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 16),

            // ── Strategy ──────────────────────────────────────────────────────
            _SectionLabel('Strategy'),
            DropdownButtonFormField<TradeStrategy>(
              initialValue: _strategy,
              dropdownColor: AppTheme.elevatedColor,
              decoration: const InputDecoration(labelText: 'Strategy *'),
              items: TradeStrategy.values
                  .map((s) => DropdownMenuItem(value: s, child: Text(s.label)))
                  .toList(),
              onChanged: (v) => setState(() => _strategy = v!),
            ),
            const SizedBox(height: 16),

            // ── Strike & Expiration ───────────────────────────────────────────
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _strikeCtrl,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                        labelText: 'Strike Price *', prefixText: '\$'),
                    validator: (v) =>
                        v == null || v.isEmpty ? 'Required' : null,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: GestureDetector(
                    onTap: _pickExpiration,
                    child: AbsorbPointer(
                      child: TextFormField(
                        decoration: InputDecoration(
                          labelText: 'Expiration *',
                          suffixIcon:
                              const Icon(Icons.calendar_today, size: 18),
                          hintText:
                              DateFormat('MMM d, yyyy').format(_expiration),
                        ),
                        initialValue:
                            DateFormat('MMM d, yyyy').format(_expiration),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'DTE at entry: $_dteAtEntry days',
              style:
                  const TextStyle(color: AppTheme.neutralColor, fontSize: 13),
            ),
            const SizedBox(height: 16),

            // ── Contracts & Entry ─────────────────────────────────────────────
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _contractsCtrl,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration:
                        const InputDecoration(labelText: 'Contracts *'),
                    validator: (v) =>
                        v == null || v.isEmpty ? 'Required' : null,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: _entryCtrl,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Entry Premium *',
                      prefixText: '\$',
                      helperText: 'Per share',
                    ),
                    validator: (v) =>
                        v == null || v.isEmpty ? 'Required' : null,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // ── Price Range & IV Entry ────────────────────────────────────────
            _SectionLabel('Price Range & IV (Optional)'),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _priceHighCtrl,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                        labelText: 'Price Range High', prefixText: '\$'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: _priceLowCtrl,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                        labelText: 'Price Range Low', prefixText: '\$'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _impliedVolEntryCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                  labelText: 'Implied Volatility at Entry', suffixText: '%'),
            ),
            const SizedBox(height: 16),

            // ── Levels ────────────────────────────────────────────────────────
            _SectionLabel('Key Levels (Optional)'),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _intradaySupportCtrl,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                        labelText: 'Intraday Support', prefixText: '\$'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: _intradayResistanceCtrl,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                        labelText: 'Intraday Resistance', prefixText: '\$'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _breakoutCtrl,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                        labelText: 'Daily Breakout', prefixText: '\$'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: _breakdownCtrl,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                        labelText: 'Daily Breakdown', prefixText: '\$'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // ── Entry Point Type ──────────────────────────────────────────────
            _SectionLabel('Entry Point'),
            Row(
              children: EntryPointType.values.map((type) {
                final selected = _entryPointType == type;
                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: GestureDetector(
                      onTap: () => setState(() => _entryPointType =
                          selected ? null : type),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        decoration: BoxDecoration(
                          color: selected
                              ? AppTheme.profitColor.withValues(alpha: 0.2)
                              : AppTheme.cardColor,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: selected
                                ? AppTheme.profitColor
                                : AppTheme.borderColor,
                          ),
                        ),
                        child: Text(
                          type.label,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: selected
                                ? AppTheme.profitColor
                                : AppTheme.neutralColor,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 16),

            // ── Max Loss & Time of Entry ──────────────────────────────────────
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _maxLossCtrl,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                        labelText: 'Max Loss', prefixText: '\$'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: _timeOfEntryCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Time of Entry',
                      hintText: 'e.g. 9:45',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // ── Greeks & IV ───────────────────────────────────────────────────
            _SectionLabel('Greeks & IV Rank (Optional)'),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _ivRankCtrl,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                        labelText: 'IV Rank', suffixText: '%'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: _deltaCtrl,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                        labelText: 'Delta', helperText: '0.01–1.00'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // ── Setup Notes ───────────────────────────────────────────────────
            TextFormField(
              controller: _notesCtrl,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Setup Notes / Rationale',
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 32),

            isLoading
                ? const Center(child: CircularProgressIndicator())
                : ElevatedButton(
                    onPressed: _submit,
                    child: const Text('Log Trade'),
                  ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}

// ── Ticker autocomplete ────────────────────────────────────────────────────────
class _TickerAutocomplete extends ConsumerStatefulWidget {
  final TextEditingController controller;
  final WidgetRef ref;
  const _TickerAutocomplete({required this.controller, required this.ref});

  @override
  ConsumerState<_TickerAutocomplete> createState() =>
      _TickerAutocompleteState();
}

class _TickerAutocompleteState extends ConsumerState<_TickerAutocomplete> {
  String _query = '';

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(() {
      final v = widget.controller.text.toUpperCase();
      if (v != _query) setState(() => _query = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    //final resultsAsync = ref.watch(tickerSearchProvider(_query));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextFormField(
          controller: widget.controller,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(
            labelText: 'Ticker Symbol *',
            prefixIcon: Icon(Icons.search),
            hintText: 'e.g. AAPL, SPY, TSLA',
          ),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z.]')),
            LengthLimitingTextInputFormatter(8),
          ],
          validator: (v) => v == null || v.isEmpty ? 'Required' : null,
        ),
        if (_query.isNotEmpty)
          resultsAsync.when(
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: LinearProgressIndicator(),
            ),
            error: (e, _) => const SizedBox.shrink(),
            data: (results) {
              if (results.isEmpty) return const SizedBox.shrink();
              return Container(
                margin: const EdgeInsets.only(top: 4),
                decoration: BoxDecoration(
                  color: AppTheme.elevatedColor,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppTheme.borderColor),
                ),
                child: Column(
                  children: results.map((r) {
                    return InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () {
                        widget.controller.text = r.symbol;
                        setState(() => _query = '');
                        FocusScope.of(context).unfocus();
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 12),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: AppTheme.profitColor
                                    .withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                r.symbol,
                                style: const TextStyle(
                                  color: AppTheme.profitColor,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                r.name,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    color: AppTheme.neutralColor, fontSize: 13),
                              ),
                            ),
                            Text(
                              r.exchange,
                              style: const TextStyle(
                                  color: AppTheme.neutralColor, fontSize: 11),
                            ),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                ),
              );
            },
          ),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: AppTheme.neutralColor,
        ),
      ),
    );
  }
}
