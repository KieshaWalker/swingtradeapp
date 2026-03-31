// =============================================================================
// features/trades/screens/trade_journal_screen.dart — Post-trade reflection
// =============================================================================
// Reached from TradeDetailScreen "Journal" button after a trade is closed.
// Loads existing journal entry (if any) via journalForTradeProvider, pre-fills
// the form, and upserts on save via tradeJournalNotifierProvider.
// =============================================================================
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../../core/theme.dart';
import '../models/trade.dart';
import '../models/trade_journal.dart';
import '../providers/trade_journal_provider.dart';

class TradeJournalScreen extends ConsumerStatefulWidget {
  final Trade trade;
  const TradeJournalScreen({super.key, required this.trade});

  @override
  ConsumerState<TradeJournalScreen> createState() => _TradeJournalScreenState();
}

class _TradeJournalScreenState extends ConsumerState<TradeJournalScreen> {
  bool _initialized = false;

  DailyTrend? _dailyTrend;
  TradeGrade? _grade;
  final _rMultipleCtrl       = TextEditingController();
  final _tagCtrl             = TextEditingController();
  final _mistakesCtrl        = TextEditingController();
  final _mindsetCtrl         = TextEditingController();
  final _postTradeNotesCtrl  = TextEditingController();
  final _shortPctCtrl        = TextEditingController();
  final _institutionalCtrl   = TextEditingController();
  final _sharesShortedCtrl   = TextEditingController();
  final _prevSharesCtrl      = TextEditingController();
  final _newsCtrl            = TextEditingController();

  bool? _exitedTooSoon;
  bool? _followedStopLoss;
  bool? _meditation;
  bool? _tookBreaks;

  @override
  void dispose() {
    _rMultipleCtrl.dispose();
    _tagCtrl.dispose();
    _mistakesCtrl.dispose();
    _mindsetCtrl.dispose();
    _postTradeNotesCtrl.dispose();
    _shortPctCtrl.dispose();
    _institutionalCtrl.dispose();
    _sharesShortedCtrl.dispose();
    _prevSharesCtrl.dispose();
    _newsCtrl.dispose();
    super.dispose();
  }

  void _prefill(TradeJournal j) {
    _dailyTrend = j.dailyTrend;
    _grade = j.grade;
    if (j.rMultiple != null) _rMultipleCtrl.text = j.rMultiple!.toString();
    if (j.tag != null) _tagCtrl.text = j.tag!;
    if (j.mistakes != null) _mistakesCtrl.text = j.mistakes!;
    if (j.mindsetNotes != null) _mindsetCtrl.text = j.mindsetNotes!;
    if (j.postTradeNotes != null) _postTradeNotesCtrl.text = j.postTradeNotes!;
    if (j.shortPct != null) _shortPctCtrl.text = j.shortPct!.toString();
    if (j.institutionalPct != null) _institutionalCtrl.text = j.institutionalPct!.toString();
    if (j.sharesShorted != null) _sharesShortedCtrl.text = j.sharesShorted!.toString();
    if (j.prevMonthSharesShorted != null) _prevSharesCtrl.text = j.prevMonthSharesShorted!.toString();
    if (j.generalNews != null) _newsCtrl.text = j.generalNews!;
    _exitedTooSoon = j.exitedTooSoon;
    _followedStopLoss = j.followedStopLoss;
    _meditation = j.meditation;
    _tookBreaks = j.tookBreaks;
  }

  Future<void> _save() async {
    final journal = TradeJournal(
      id: const Uuid().v4(),
      tradeId: widget.trade.id,
      userId: widget.trade.userId,
      dailyTrend: _dailyTrend,
      rMultiple: _rMultipleCtrl.text.isNotEmpty
          ? double.tryParse(_rMultipleCtrl.text)
          : null,
      grade: _grade,
      tag: _tagCtrl.text.isNotEmpty ? _tagCtrl.text : null,
      mistakes: _mistakesCtrl.text.isNotEmpty ? _mistakesCtrl.text : null,
      exitedTooSoon: _exitedTooSoon,
      followedStopLoss: _followedStopLoss,
      meditation: _meditation,
      tookBreaks: _tookBreaks,
      mindsetNotes: _mindsetCtrl.text.isNotEmpty ? _mindsetCtrl.text : null,
      postTradeNotes: _postTradeNotesCtrl.text.isNotEmpty ? _postTradeNotesCtrl.text : null,
      shortPct: _shortPctCtrl.text.isNotEmpty ? double.tryParse(_shortPctCtrl.text) : null,
      institutionalPct: _institutionalCtrl.text.isNotEmpty ? double.tryParse(_institutionalCtrl.text) : null,
      sharesShorted: _sharesShortedCtrl.text.isNotEmpty ? double.tryParse(_sharesShortedCtrl.text) : null,
      prevMonthSharesShorted: _prevSharesCtrl.text.isNotEmpty ? double.tryParse(_prevSharesCtrl.text) : null,
      generalNews: _newsCtrl.text.isNotEmpty ? _newsCtrl.text : null,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );

    await ref.read(tradeJournalNotifierProvider.notifier).upsertJournal(journal);

    if (mounted) {
      final st = ref.read(tradeJournalNotifierProvider);
      if (st.hasError) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: ${st.error}'), backgroundColor: AppTheme.lossColor),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Journal saved.')),
        );
        Navigator.pop(context);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final journalAsync = ref.watch(journalForTradeProvider(widget.trade.id));

    return journalAsync.when(
      loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(body: Center(child: Text('Error: $e'))),
      data: (existing) {
        if (!_initialized) {
          if (existing != null) _prefill(existing);
          _initialized = true;
        }
        return _buildForm(context);
      },
    );
  }

  Widget _buildForm(BuildContext context) {
    final isLoading = ref.watch(tradeJournalNotifierProvider).isLoading;

    return Scaffold(
      appBar: AppBar(
        title: Text('Journal — ${widget.trade.ticker}'),
        actions: [
          TextButton(
            onPressed: isLoading ? null : _save,
            child: const Text('Save'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── Trade summary chip ────────────────────────────────────────────
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppTheme.cardColor,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${widget.trade.ticker} · ${widget.trade.strategy.label}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                if (widget.trade.realizedPnl != null)
                  Text(
                    '${widget.trade.realizedPnl! >= 0 ? '+' : ''}\$${widget.trade.realizedPnl!.toStringAsFixed(0)}',
                    style: TextStyle(
                      color: widget.trade.isProfitable
                          ? AppTheme.profitColor
                          : AppTheme.lossColor,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // ── Daily trend ───────────────────────────────────────────────────
          _SectionLabel('Daily Trend'),
          Wrap(
            spacing: 8,
            children: DailyTrend.values.map((t) {
              final selected = _dailyTrend == t;
              return ChoiceChip(
                label: Text(t.label),
                selected: selected,
                onSelected: (_) =>
                    setState(() => _dailyTrend = selected ? null : t),
                selectedColor: AppTheme.profitColor.withValues(alpha: 0.25),
                labelStyle: TextStyle(
                  color: selected ? AppTheme.profitColor : AppTheme.neutralColor,
                  fontWeight: FontWeight.w600,
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 16),

          // ── Grade ─────────────────────────────────────────────────────────
          _SectionLabel('Trade Grade'),
          Wrap(
            spacing: 8,
            children: TradeGrade.values.map((g) {
              final selected = _grade == g;
              final color = switch (g) {
                TradeGrade.a => AppTheme.profitColor,
                TradeGrade.b => const Color(0xFF7EC8E3),
                TradeGrade.c => AppTheme.neutralColor,
                TradeGrade.d => Colors.orange,
                TradeGrade.f => AppTheme.lossColor,
              };
              return ChoiceChip(
                label: Text(g.label),
                selected: selected,
                onSelected: (_) =>
                    setState(() => _grade = selected ? null : g),
                selectedColor: color.withValues(alpha: 0.25),
                labelStyle: TextStyle(
                  color: selected ? color : AppTheme.neutralColor,
                  fontWeight: FontWeight.w700,
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 16),

          // ── R Multiple & Tag ──────────────────────────────────────────────
          Row(
            children: [
              Expanded(
                child: TextFormField(
                  controller: _rMultipleCtrl,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true, signed: true),
                  decoration: const InputDecoration(
                    labelText: 'R Multiple',
                    helperText: 'PnL ÷ Max Loss',
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextFormField(
                  controller: _tagCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Tag',
                    hintText: 'e.g. momentum',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // ── Checkboxes ────────────────────────────────────────────────────
          _SectionLabel('Discipline Checklist'),
          _CheckRow(
            label: 'Exited too soon (left profits)',
            value: _exitedTooSoon,
            onChanged: (v) => setState(() => _exitedTooSoon = v),
          ),
          _CheckRow(
            label: 'Followed stop-loss rule',
            value: _followedStopLoss,
            onChanged: (v) => setState(() => _followedStopLoss = v),
          ),
          _CheckRow(
            label: 'Meditated today',
            value: _meditation,
            onChanged: (v) => setState(() => _meditation = v),
          ),
          _CheckRow(
            label: 'Took 30-min breaks',
            value: _tookBreaks,
            onChanged: (v) => setState(() => _tookBreaks = v),
          ),
          const SizedBox(height: 16),

          // ── Mistakes & mindset ────────────────────────────────────────────
          TextFormField(
            controller: _mistakesCtrl,
            maxLines: 2,
            decoration: const InputDecoration(
              labelText: 'Mistakes',
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _mindsetCtrl,
            maxLines: 2,
            decoration: const InputDecoration(
              labelText: 'My Mindset',
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _postTradeNotesCtrl,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Post-Trade Notes',
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 20),

          // ── Short interest / research ─────────────────────────────────────
          _SectionLabel('Short Interest & Research (Optional)'),
          Row(
            children: [
              Expanded(
                child: TextFormField(
                  controller: _shortPctCtrl,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                      labelText: '% Short', suffixText: '%'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextFormField(
                  controller: _institutionalCtrl,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                      labelText: '% Institutional', suffixText: '%'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextFormField(
                  controller: _sharesShortedCtrl,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Shares Shorted'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextFormField(
                  controller: _prevSharesCtrl,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Prev Month Shorted'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _newsCtrl,
            maxLines: 2,
            decoration: const InputDecoration(
              labelText: 'General News',
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 32),

          isLoading
              ? const Center(child: CircularProgressIndicator())
              : ElevatedButton(
                  onPressed: _save,
                  child: const Text('Save Journal'),
                ),
          const SizedBox(height: 16),
        ],
      ),
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
            color: AppTheme.neutralColor),
      ),
    );
  }
}

class _CheckRow extends StatelessWidget {
  final String label;
  final bool? value;
  final ValueChanged<bool?> onChanged;
  const _CheckRow(
      {required this.label, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Checkbox(
          value: value,
          tristate: true,
          onChanged: onChanged,
          activeColor: AppTheme.profitColor,
        ),
        Expanded(
          child: Text(label,
              style: const TextStyle(color: AppTheme.neutralColor)),
        ),
      ],
    );
  }
}
