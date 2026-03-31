// =============================================================================
// features/trades/screens/csv_import_screen.dart — Paste journal CSV
// =============================================================================
// User pastes the raw CSV text from their monthly options journal spreadsheet.
// Parses the column-per-trade layout, shows a preview, then batch-imports
// trades + journal entries on confirm.
//
// Column layout (row numbers match spreadsheet rows, 1-based):
//   row 21: date         row 22: time of entry  row 23: ticker
//   row 26: entry price  row 27: intraday support row 28: intraday resistance
//   row 29: daily breakout  row 30: daily breakdown
//   row 33: exit price   row 34: time of exit   row 36: contracts
//   row 37: max loss     row 38: expiration date
//   row 42: daily trend  row 43: grade (A–F)    row 44: mistakes
//   row 45: exited too soon  row 48: R multiple  row 49: w/l  row 50: tag
//   row 52: mindset      row 55: meditation (y/n)
//   row 56: took breaks (y/n)  row 57: followed stop-loss (y/n)
// =============================================================================
import 'package:csv/csv.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';
import '../../../core/theme.dart';
import '../../auth/providers/auth_provider.dart';
import '../models/trade.dart';
import '../models/trade_journal.dart';
import '../providers/trade_journal_provider.dart';
import '../providers/trades_provider.dart';

class CsvImportScreen extends ConsumerStatefulWidget {
  const CsvImportScreen({super.key});

  @override
  ConsumerState<CsvImportScreen> createState() => _CsvImportScreenState();
}

class _CsvImportScreenState extends ConsumerState<CsvImportScreen> {
  final _pasteCtrl = TextEditingController();
  List<_ParsedRow> _rows = [];
  bool _importing = false;
  String? _error;

  @override
  void dispose() {
    _pasteCtrl.dispose();
    super.dispose();
  }

  void _parse() {
    setState(() { _error = null; _rows = []; });
    final text = _pasteCtrl.text.trim();
    if (text.isEmpty) {
      setState(() => _error = 'Paste your CSV text first.');
      return;
    }
    try {
      final table = const CsvToListConverter(eol: '\n').convert(text);
      final parsed = _parseCsvTable(table);
      setState(() => _rows = parsed);
      if (parsed.isEmpty) {
        setState(() => _error = 'No trade columns found. Check your CSV format.');
      }
    } catch (e) {
      setState(() => _error = 'Parse error: $e');
    }
  }

  List<_ParsedRow> _parseCsvTable(List<List<dynamic>> table) {
    if (table.length < 50) return [];

    String cell(int row, int col) {
      // row is 1-based (spreadsheet row number)
      final r0 = row - 1;
      if (r0 >= table.length) return '';
      final r = table[r0];
      if (col >= r.length) return '';
      return r[col].toString().trim();
    }

    final results = <_ParsedRow>[];

    // Trade columns: B=1, C=2 … U=20 (spreadsheet cols B–U = indices 1–20)
    for (var col = 1; col <= 20; col++) {
      final ticker = cell(23, col).toUpperCase();
      if (ticker.isEmpty) continue;

      final entryStr = cell(26, col);
      final entry = double.tryParse(
          entryStr.replaceAll('\$', '').replaceAll(',', ''));
      if (entry == null) continue;

      results.add(_ParsedRow(
        ticker: ticker,
        dateStr: cell(21, col),
        timeOfEntry: cell(22, col),
        timeOfExit: cell(34, col),
        entryPrice: entry,
        exitPrice: double.tryParse(
            cell(33, col).replaceAll('\$', '').replaceAll(',', '')),
        contracts: int.tryParse(cell(36, col)) ?? 1,
        maxLoss: double.tryParse(
            cell(37, col).replaceAll('\$', '').replaceAll(',', '')),
        expirationStr: cell(38, col),
        intradaySupport: double.tryParse(cell(27, col).replaceAll('\$', '')),
        intradayResistance: double.tryParse(cell(28, col).replaceAll('\$', '')),
        dailyBreakout: double.tryParse(cell(29, col).replaceAll('\$', '')),
        dailyBreakdown: double.tryParse(cell(30, col).replaceAll('\$', '')),
        dailyTrend: _parseTrend(cell(42, col)),
        grade: _parseGrade(cell(43, col)),
        mistakes: cell(44, col).isNotEmpty ? cell(44, col) : null,
        exitedTooSoon: _parseBool(cell(45, col)),
        rMultiple: double.tryParse(cell(48, col)),
        tag: cell(50, col).isNotEmpty ? cell(50, col) : null,
        mindset: cell(52, col).isNotEmpty ? cell(52, col) : null,
        meditation: _parseBool(cell(55, col)),
        tookBreaks: _parseBool(cell(56, col)),
        followedStopLoss: _parseBool(cell(57, col)),
      ));
    }
    return results;
  }

  DailyTrend? _parseTrend(String v) {
    final l = v.toLowerCase();
    if (l.contains('bull')) return DailyTrend.bullish;
    if (l.contains('bear')) return DailyTrend.bearish;
    if (l.contains('side')) return DailyTrend.sideways;
    if (l.contains('chop')) return DailyTrend.choppy;
    return null;
  }

  TradeGrade? _parseGrade(String v) => switch (v.trim().toUpperCase()) {
        'A' => TradeGrade.a,
        'B' => TradeGrade.b,
        'C' => TradeGrade.c,
        'D' => TradeGrade.d,
        'F' => TradeGrade.f,
        _ => null,
      };

  bool? _parseBool(String v) {
    final l = v.toLowerCase();
    if (l == 'y' || l == 'yes' || l == 'true' || l == '1') return true;
    if (l == 'n' || l == 'no' || l == 'false' || l == '0') return false;
    return null;
  }

  Future<void> _import() async {
    final user = ref.read(currentUserProvider);
    if (user == null) return;
    setState(() => _importing = true);

    try {
      final now = DateTime.now();
      for (final row in _rows) {
        final tradeId = const Uuid().v4();

        DateTime openedAt;
        try {
          final parsed = DateFormat('EEEE M/d').parse(row.dateStr);
          openedAt = DateTime(now.year, parsed.month, parsed.day);
        } catch (_) {
          openedAt = now;
        }

        DateTime? expiration;
        for (final fmt in ['M/d/yy', 'M/d/yyyy']) {
          try {
            expiration = DateFormat(fmt).parse(row.expirationStr);
            break;
          } catch (_) {}
        }
        expiration ??= openedAt.add(const Duration(days: 30));

        final hasExit = row.exitPrice != null;

        final trade = Trade(
          id: tradeId,
          userId: user.id,
          ticker: row.ticker,
          optionType: OptionType.call,
          strategy: TradeStrategy.other,
          strike: 0,
          expiration: expiration,
          dteAtEntry: expiration.difference(openedAt).inDays,
          contracts: row.contracts,
          entryPrice: row.entryPrice,
          exitPrice: row.exitPrice,
          status: hasExit ? TradeStatus.closed : TradeStatus.open,
          openedAt: openedAt,
          closedAt: hasExit ? openedAt : null,
          maxLoss: row.maxLoss,
          timeOfEntry: row.timeOfEntry.isNotEmpty ? row.timeOfEntry : null,
          timeOfExit: row.timeOfExit.isNotEmpty ? row.timeOfExit : null,
          intradaySupport: row.intradaySupport,
          intradayResistance: row.intradayResistance,
          dailyBreakoutLevel: row.dailyBreakout,
          dailyBreakdownLevel: row.dailyBreakdown,
        );

        await ref.read(tradesNotifierProvider.notifier).addTrade(trade);

        if (row.grade != null ||
            row.dailyTrend != null ||
            row.mistakes != null ||
            row.tag != null) {
          final journal = TradeJournal(
            id: const Uuid().v4(),
            tradeId: tradeId,
            userId: user.id,
            dailyTrend: row.dailyTrend,
            rMultiple: row.rMultiple,
            grade: row.grade,
            tag: row.tag,
            mistakes: row.mistakes,
            exitedTooSoon: row.exitedTooSoon,
            followedStopLoss: row.followedStopLoss,
            meditation: row.meditation,
            tookBreaks: row.tookBreaks,
            mindsetNotes: row.mindset,
            createdAt: now,
            updatedAt: now,
          );
          await ref
              .read(tradeJournalNotifierProvider.notifier)
              .upsertJournal(journal);
        }
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Imported ${_rows.length} trades.')),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) setState(() { _error = 'Import failed: $e'; _importing = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Paste CSV Journal'),
        actions: [
          if (_rows.isNotEmpty)
            TextButton(
              onPressed: _importing ? null : _import,
              child: const Text('Import'),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Instructions
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppTheme.cardColor,
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('How to paste',
                    style: TextStyle(fontWeight: FontWeight.w700)),
                SizedBox(height: 6),
                Text(
                  '1. Open your monthly journal spreadsheet.\n'
                  '2. Select all cells (Cmd+A / Ctrl+A).\n'
                  '3. Copy (Cmd+C / Ctrl+C).\n'
                  '4. Paste below and tap Preview.',
                  style: TextStyle(color: AppTheme.neutralColor, fontSize: 13),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Paste field
          TextField(
            controller: _pasteCtrl,
            maxLines: 8,
            style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
            decoration: InputDecoration(
              hintText: 'Paste CSV here…',
              hintStyle: const TextStyle(color: AppTheme.neutralColor),
              alignLabelWithHint: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: AppTheme.borderColor),
              ),
              contentPadding: const EdgeInsets.all(12),
            ),
          ),
          const SizedBox(height: 12),

          ElevatedButton.icon(
            onPressed: _parse,
            icon: const Icon(Icons.search),
            label: const Text('Preview Trades'),
          ),

          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!,
                style:
                    const TextStyle(color: AppTheme.lossColor, fontSize: 13)),
          ],

          if (_importing) ...[
            const SizedBox(height: 24),
            const Center(child: CircularProgressIndicator()),
            const SizedBox(height: 8),
            const Center(
              child: Text('Importing…',
                  style: TextStyle(color: AppTheme.neutralColor)),
            ),
          ],

          if (_rows.isNotEmpty) ...[
            const SizedBox(height: 20),
            Text(
              '${_rows.length} trade${_rows.length == 1 ? '' : 's'} found — tap Import to confirm:',
              style: const TextStyle(
                  fontWeight: FontWeight.w600, color: AppTheme.neutralColor),
            ),
            const SizedBox(height: 10),
            ..._rows.map((r) => _PreviewCard(row: r)),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _importing ? null : _import,
              child: Text('Import ${_rows.length} Trade${_rows.length == 1 ? '' : 's'}'),
            ),
          ],
        ],
      ),
    );
  }
}

// ── Preview card ───────────────────────────────────────────────────────────────

class _PreviewCard extends StatelessWidget {
  final _ParsedRow row;
  const _PreviewCard({required this.row});

  @override
  Widget build(BuildContext context) {
    final hasExit = row.exitPrice != null;
    final pnl = hasExit
        ? (row.exitPrice! - row.entryPrice) * row.contracts * 100
        : null;
    final pnlColor = pnl == null
        ? AppTheme.neutralColor
        : pnl >= 0
            ? AppTheme.profitColor
            : AppTheme.lossColor;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(row.ticker,
                      style: const TextStyle(
                          fontWeight: FontWeight.w800, fontSize: 15)),
                  Text(
                    '${row.dateStr}  ·  ${row.contracts}x  ·  entry \$${row.entryPrice.toStringAsFixed(2)}',
                    style: const TextStyle(
                        color: AppTheme.neutralColor, fontSize: 12),
                  ),
                  if (row.grade != null || row.tag != null)
                    Text(
                      [
                        if (row.grade != null) 'Grade: ${row.grade!.label}',
                        if (row.tag != null) row.tag!,
                      ].join('  ·  '),
                      style: const TextStyle(
                          color: AppTheme.neutralColor, fontSize: 12),
                    ),
                ],
              ),
            ),
            if (pnl != null)
              Text(
                '${pnl >= 0 ? '+' : ''}\$${pnl.toStringAsFixed(0)}',
                style: TextStyle(
                    color: pnlColor,
                    fontWeight: FontWeight.w700,
                    fontSize: 14),
              ),
          ],
        ),
      ),
    );
  }
}

// ── Internal parsed row ────────────────────────────────────────────────────────

class _ParsedRow {
  final String ticker;
  final String dateStr;
  final String timeOfEntry;
  final String timeOfExit;
  final double entryPrice;
  final double? exitPrice;
  final int contracts;
  final double? maxLoss;
  final String expirationStr;
  final double? intradaySupport;
  final double? intradayResistance;
  final double? dailyBreakout;
  final double? dailyBreakdown;
  final DailyTrend? dailyTrend;
  final TradeGrade? grade;
  final String? mistakes;
  final bool? exitedTooSoon;
  final double? rMultiple;
  final String? tag;
  final String? mindset;
  final bool? meditation;
  final bool? tookBreaks;
  final bool? followedStopLoss;

  const _ParsedRow({
    required this.ticker,
    required this.dateStr,
    required this.timeOfEntry,
    required this.timeOfExit,
    required this.entryPrice,
    this.exitPrice,
    required this.contracts,
    this.maxLoss,
    required this.expirationStr,
    this.intradaySupport,
    this.intradayResistance,
    this.dailyBreakout,
    this.dailyBreakdown,
    this.dailyTrend,
    this.grade,
    this.mistakes,
    this.exitedTooSoon,
    this.rMultiple,
    this.tag,
    this.mindset,
    this.meditation,
    this.tookBreaks,
    this.followedStopLoss,
  });
}
