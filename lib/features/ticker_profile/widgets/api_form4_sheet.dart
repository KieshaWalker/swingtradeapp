// =============================================================================
// features/ticker_profile/widgets/api_form4_sheet.dart
// =============================================================================
// Bottom sheet for importing Form 4 insider transactions directly from the
// SEC EDGAR API — no paste required.
//
// Two-step flow:
//   Step 0 — List of recent Form 4 filings for the ticker (from API)
//             Tap a row → app fetches the filing XML automatically
//   Step 1 — Preview parsed transactions (checkboxes) → Save button
//
// Writes via: tickerProfileNotifierProvider.addInsiderBuys()
// Dedup: filings already imported (accessionNo match) are badged "Imported"
//
// XML parsing (Form 4 EDGAR format):
//   Owner name/title: <rptOwnerName>, <officerTitle>
//   Transactions:     <nonDerivativeTransaction> blocks
//     date:   <transactionDate><value>…</value>
//     code:   <transactionCode>…</transactionCode>
//     shares: <transactionShares><value>…</value>
//     price:  <transactionPricePerShare><value>…</value>
//     A/D:    <transactionAcquiredDisposedCode><value>…</value>
// =============================================================================
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import '../../../core/theme.dart';
import '../../../services/sec/sec_models.dart';
import '../../../services/sec/sec_providers.dart';
import '../models/ticker_profile_models.dart';
import '../providers/ticker_profile_notifier.dart';
import '../providers/ticker_profile_providers.dart';

// ─── Internal parsed-row model ────────────────────────────────────────────────

class _TxRow {
  final String insiderName;
  final String? insiderTitle;
  final DateTime txDate;
  final String rawCode;
  final int shares;
  final double? price;
  final String disposition; // 'A' or 'D'
  final InsiderTransactionType txType;
  bool selected;

  _TxRow({
    required this.insiderName,
    this.insiderTitle,
    required this.txDate,
    required this.rawCode,
    required this.shares,
    this.price,
    required this.disposition,
    required this.txType,
    this.selected = true,
  });
}

// ─── Sheet widget ─────────────────────────────────────────────────────────────

class ApiForm4Sheet extends ConsumerStatefulWidget {
  final String symbol;
  const ApiForm4Sheet({super.key, required this.symbol});

  @override
  ConsumerState<ApiForm4Sheet> createState() => _ApiForm4SheetState();
}

class _ApiForm4SheetState extends ConsumerState<ApiForm4Sheet> {
  int _step = 0;
  SecFiling? _selectedFiling;
  List<_TxRow> _rows = [];
  bool _loadingXml = false;
  String? _loadError;
  bool _saving = false;

  // ── XML parser ──────────────────────────────────────────────────────────────

  // Extracts the text inside <tag><value>…</value></tag>
  static String _xmlVal(String xml, String tag) {
    final m = RegExp(
            '<$tag>\\s*(?:<footnotesRef[^/]*/?>)?\\s*<value>([^<]*)</value>',
            dotAll: true)
        .firstMatch(xml);
    return m?.group(1)?.trim() ?? '';
  }

  // Extracts the direct text content of <tag>…</tag> (no nested <value>)
  static String _directVal(String xml, String tag) {
    final m = RegExp('<$tag>([^<]*)</$tag>').firstMatch(xml);
    return m?.group(1)?.trim() ?? '';
  }

  static InsiderTransactionType _codeToType(String code) {
    return switch (code.toUpperCase()) {
      'P' => InsiderTransactionType.purchase,
      'S' => InsiderTransactionType.sale,
      'F' => InsiderTransactionType.taxWithholding,
      'M' || 'X' => InsiderTransactionType.exercise,
      'G' => InsiderTransactionType.gift,
      _ => InsiderTransactionType.other,
    };
  }

  static String _codeDesc(String code) {
    return switch (code.toUpperCase()) {
      'P' => 'Purchase',
      'S' => 'Open-mkt sale',
      'F' => 'Tax withholding',
      'M' => 'Option exercise',
      'X' => 'In-the-money exercise',
      'G' => 'Gift',
      'A' => 'Grant / award',
      _ => code,
    };
  }

  List<_TxRow> _parseXml(String xml, SecFiling filing) {
    // Prefer owner name from XML; fall back to what the API returned in entities
    final ownerName = _directVal(xml, 'rptOwnerName').isNotEmpty
        ? _directVal(xml, 'rptOwnerName')
        : filing.reportingOwnerName ?? 'Unknown';

    final title = _directVal(xml, 'officerTitle').isNotEmpty
        ? _directVal(xml, 'officerTitle')
        : null;

    final rows = <_TxRow>[];

    // Parse non-derivative transactions (common stock purchases/sales)
    final txBlock =
        RegExp(r'<nonDerivativeTransaction>(.*?)</nonDerivativeTransaction>',
                dotAll: true)
            .allMatches(xml);

    for (final m in txBlock) {
      final block = m.group(1)!;
      final dateStr = _xmlVal(block, 'transactionDate');
      final code = _directVal(block, 'transactionCode');
      final sharesStr = _xmlVal(block, 'transactionShares');
      final priceStr = _xmlVal(block, 'transactionPricePerShare');
      final disposition = _xmlVal(block, 'transactionAcquiredDisposedCode');

      if (dateStr.isEmpty || code.isEmpty) continue;
      final shares = int.tryParse(sharesStr.replaceAll(',', ''));
      if (shares == null || shares == 0) continue;

      DateTime date;
      try {
        date = DateTime.parse(dateStr);
      } catch (_) {
        continue;
      }

      final price = double.tryParse(priceStr.replaceAll(',', ''));

      rows.add(_TxRow(
        insiderName: ownerName,
        insiderTitle: title,
        txDate: date,
        rawCode: code,
        shares: shares,
        price: price,
        disposition: disposition.isEmpty ? 'A' : disposition,
        txType: _codeToType(code),
        selected: true,
      ));
    }
    return rows;
  }

  // ── Filing tap → fetch XML ──────────────────────────────────────────────────

  Future<void> _onFilingTap(SecFiling filing) async {
    final xmlUrl = filing.xmlUrl;
    if (xmlUrl == null) {
      setState(() => _loadError = 'No XML document found for this filing.');
      return;
    }

    setState(() {
      _loadingXml = true;
      _loadError = null;
      _selectedFiling = filing;
    });

    try {
      final res = await http.get(Uri.parse(xmlUrl));
      if (res.statusCode != 200) {
        setState(() {
          _loadError = 'Could not fetch filing XML (HTTP ${res.statusCode}).';
          _loadingXml = false;
        });
        return;
      }

      final parsed = _parseXml(res.body, filing);
      if (parsed.isEmpty) {
        setState(() {
          _loadError =
              'No non-derivative transactions found in this filing.';
          _loadingXml = false;
        });
        return;
      }

      setState(() {
        _rows = parsed;
        _loadingXml = false;
        _step = 1;
      });
    } catch (e) {
      setState(() {
        _loadError = 'Failed to load filing: $e';
        _loadingXml = false;
      });
    }
  }

  // ── Save ────────────────────────────────────────────────────────────────────

  Future<void> _save() async {
    final filing = _selectedFiling!;
    final selected = _rows.where((r) => r.selected).toList();
    if (selected.isEmpty) return;
    setState(() => _saving = true);

    final buys = selected
        .map((r) => TickerInsiderBuy(
              id: '',
              userId: '',
              ticker: widget.symbol,
              insiderName: r.insiderName,
              insiderTitle: r.insiderTitle,
              shares: r.shares,
              pricePerShare: r.price,
              totalValue: r.price != null ? r.price! * r.shares : null,
              filedAt: filing.filedAt,
              transactionDate: r.txDate,
              accessionNo: filing.accessionNo,
              transactionType: r.txType,
              notes: 'Form 4 · ${_codeDesc(r.rawCode)}',
            ))
        .toList();

    try {
      await ref
          .read(tickerProfileNotifierProvider.notifier)
          .addInsiderBuys(widget.symbol, buys);
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ── Helpers ─────────────────────────────────────────────────────────────────

  String _fmtDate(DateTime d) =>
      DateFormat('MMM d, yy').format(d);

  String _fmtShares(int n) => n.toString().replaceAllMapped(
        RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
        (m) => '${m[1]},',
      );

  String _fmtFull(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  // ── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 24,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: _step == 0 ? _buildFilingList() : _buildPreviewStep(),
    );
  }

  Widget _buildFilingList() {
    final filingsAsync = ref.watch(secForm4FilingsProvider(widget.symbol));
    final existingAsync = ref.watch(tickerInsiderBuysProvider(widget.symbol));

    final importedAccessions = existingAsync.valueOrNull
            ?.map((b) => b.accessionNo)
            .whereType<String>()
            .toSet() ??
        const <String>{};

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Import Form 4 — ${widget.symbol}',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 4),
        Text(
          'Tap a filing to import insider transactions.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 16),
        if (_loadingXml)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: CircularProgressIndicator()),
          )
        else ...[
          if (_loadError != null) ...[
            Text(
              _loadError!,
              style: TextStyle(
                  color: Theme.of(context).colorScheme.error, fontSize: 12),
            ),
            const SizedBox(height: 8),
          ],
          filingsAsync.when(
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (e, _) => Text(
              'Could not load SEC filings.',
              style: TextStyle(
                  color: Theme.of(context).colorScheme.error, fontSize: 13),
            ),
            data: (filings) {
              if (filings.isEmpty) {
                return const Text(
                  'No Form 4 filings found for this ticker.',
                  style: TextStyle(color: AppTheme.neutralColor),
                );
              }
              return Column(
                children: filings
                    .map((f) => _FilingRow(
                          filing: f,
                          alreadyImported:
                              importedAccessions.contains(f.accessionNo),
                          dateLabel: _fmtDate(f.filedAt),
                          onTap: () => _onFilingTap(f),
                        ))
                    .toList(),
              );
            },
          ),
        ],
      ],
    );
  }

  Widget _buildPreviewStep() {
    final filing = _selectedFiling!;
    final selectedCount = _rows.where((r) => r.selected).length;
    final ownerName = _rows.isNotEmpty ? _rows.first.insiderName : '';

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back),
              padding: EdgeInsets.zero,
              onPressed: () => setState(() {
                _step = 0;
                _loadError = null;
              }),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                '${_rows.length} transaction${_rows.length == 1 ? '' : 's'} · ${widget.symbol}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          ],
        ),
        Text(
          '$ownerName · Filed ${_fmtDate(filing.filedAt)}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        ..._rows.asMap().entries.map((e) {
          final i = e.key;
          final r = e.value;
          final dispIcon = r.disposition == 'D' ? '▼' : '▲';
          final dispColor =
              r.disposition == 'D' ? Colors.redAccent : Colors.greenAccent;
          return CheckboxListTile(
            value: r.selected,
            onChanged: (v) =>
                setState(() => _rows[i].selected = v ?? false),
            title: Row(
              children: [
                Text(dispIcon,
                    style: TextStyle(color: dispColor, fontSize: 13)),
                const SizedBox(width: 4),
                Text(
                  '${_fmtShares(r.shares)} sh  ·  ${_codeDesc(r.rawCode)}',
                  style: const TextStyle(fontSize: 13),
                ),
              ],
            ),
            subtitle: Text(
              '${_fmtFull(r.txDate)}'
              '${r.price != null ? '  ·  \$${r.price!.toStringAsFixed(4).replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '')}' : ''}',
              style: const TextStyle(fontSize: 12),
            ),
            contentPadding: EdgeInsets.zero,
            dense: true,
          );
        }),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _saving || selectedCount == 0 ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(
                  'Save $selectedCount Transaction${selectedCount == 1 ? '' : 's'}'),
        ),
      ],
    );
  }
}

// ─── Filing list row ──────────────────────────────────────────────────────────

class _FilingRow extends StatelessWidget {
  final SecFiling filing;
  final bool alreadyImported;
  final String dateLabel;
  final VoidCallback onTap;

  const _FilingRow({
    required this.filing,
    required this.alreadyImported,
    required this.dateLabel,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final name =
        filing.reportingOwnerName ?? filing.companyName;

    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    'Filed $dateLabel',
                    style: const TextStyle(
                        fontSize: 11, color: AppTheme.neutralColor),
                  ),
                ],
              ),
            ),
            if (alreadyImported)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: AppTheme.profitColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  'Imported',
                  style: TextStyle(
                      color: AppTheme.profitColor,
                      fontSize: 10,
                      fontWeight: FontWeight.w700),
                ),
              ),
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right,
                size: 16, color: AppTheme.neutralColor),
          ],
        ),
      ),
    );
  }
}
