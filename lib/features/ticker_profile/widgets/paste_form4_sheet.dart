// =============================================================================
// features/ticker_profile/widgets/paste_form4_sheet.dart
// =============================================================================
// Bottom sheet for bulk-importing Form 4 transactions by pasting the raw SEC
// EDGAR text directly from the browser.
//
// Two-step flow:
//   Step 0 — Paste raw Form 4 text + set filing date → Parse button
//   Step 1 — Preview parsed transactions (checkboxes) → Save button
//
// Writes via: tickerProfileNotifierProvider.addInsiderBuys()
//
// Parsing handles the standard EDGAR copy-paste format:
//   • Insider name: line before "(Last)"
//   • Ticker: inside "[ NVDA ]" brackets
//   • Title: line after "Officer (give title below)" or "Director" role line
//   • Table rows: Common Stock  MM/DD/YYYY  CODE(n)  SHARES(n)  A/D  $PRICE(n)
// =============================================================================
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/ticker_profile_models.dart';
import '../providers/ticker_profile_notifier.dart';

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

class PasteForm4Sheet extends ConsumerStatefulWidget {
  final String symbol;
  const PasteForm4Sheet({super.key, required this.symbol});

  @override
  ConsumerState<PasteForm4Sheet> createState() => _PasteForm4SheetState();
}

class _PasteForm4SheetState extends ConsumerState<PasteForm4Sheet> {
  final _pasteCtrl = TextEditingController();
  int _step = 0;
  List<_TxRow> _rows = [];
  DateTime _filedAt = DateTime.now();
  bool _saving = false;
  String? _parseError;
  String _parsedTicker = '';
  String _parsedName = '';

  @override
  void dispose() {
    _pasteCtrl.dispose();
    super.dispose();
  }

  // ── Parser ──────────────────────────────────────────────────────────────────

  static String? _extractName(String text) {
    // Line immediately before "(Last)" label
    final m = RegExp(r'([^\n\(]+)\n[^\n]*\(Last\)', multiLine: true)
        .firstMatch(text);
    if (m != null) {
      final name = m.group(1)?.trim();
      if (name != null && name.isNotEmpty) return name;
    }
    // Fallback: line after "Reporting Person*"
    final m2 =
        RegExp(r'Reporting Person\*?\s*\n([^\n]+)', multiLine: true)
            .firstMatch(text);
    return m2?.group(1)?.trim();
  }

  static String? _extractTitle(String text) {
    // Line after "Officer (give title below)"
    final m = RegExp(
            r'Officer\s*\(give title below\)[^\n]*\n\s*([^\n\s][^\n]*)',
            multiLine: true)
        .firstMatch(text);
    if (m != null) {
      final title = m.group(1)?.trim();
      if (title != null && title.isNotEmpty) return title;
    }
    // Fallback: keyword-based title detection
    final kw = RegExp(
        r'((?:Chief|Principal|Senior|Vice|Executive|President|General|Independent|Managing)'
        r'\s+[A-Za-z\s]+(?:Officer|Director|Counsel|Trustee|Partner|President))',
        multiLine: true);
    return kw.firstMatch(text)?.group(1)?.trim();
  }

  static String? _extractTicker(String text) {
    final m = RegExp(r'\[\s*([A-Z0-9.\-]{1,5})\s*\]').firstMatch(text);
    return m?.group(1);
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

  List<_TxRow> _parse(String raw) {
    final text = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final name = _extractName(text) ?? 'Unknown';
    final title = _extractTitle(text);
    _parsedName = name;
    _parsedTicker = _extractTicker(text) ?? widget.symbol;

    // Pattern: date  CODE(opt footnote)  SHARES(opt footnote)  A/D  $PRICE(opt footnote)
    final rowPattern = RegExp(
      r'(\d{2}/\d{2}/\d{4})\s+'       // transaction date MM/DD/YYYY
      r'([A-Z]+)(?:\(\d+\))?\s+'       // code, optional "(n)" footnote
      r'([\d,]+)(?:\(\d+\))?\s+'       // shares, optional "(n)" footnote
      r'([AD])\s+'                      // A (acquired) or D (disposed)
      r'\$?([\d,]+(?:\.\d+)?)(?:\(\d+\))?', // price, optional "(n)" footnote
      multiLine: true,
    );

    final rows = <_TxRow>[];
    for (final m in rowPattern.allMatches(text)) {
      final dateStr = m.group(1)!;
      final code = m.group(2)!;
      final shares = int.tryParse(m.group(3)!.replaceAll(',', ''));
      final disposition = m.group(4)!;
      final price = double.tryParse(m.group(5)!.replaceAll(',', ''));

      if (shares == null || shares == 0) continue;

      final parts = dateStr.split('/');
      final date = DateTime(
        int.parse(parts[2]),
        int.parse(parts[0]),
        int.parse(parts[1]),
      );

      rows.add(_TxRow(
        insiderName: name,
        insiderTitle: title,
        txDate: date,
        rawCode: code,
        shares: shares,
        price: price,
        disposition: disposition,
        txType: _codeToType(code),
        selected: true,
      ));
    }
    return rows;
  }

  void _doParse() {
    final text = _pasteCtrl.text.trim();
    if (text.isEmpty) return;
    final rows = _parse(text);
    if (rows.isEmpty) {
      setState(() {
        _parseError =
            'No transactions found. Make sure to paste the complete Form 4 text from SEC EDGAR.';
      });
    } else {
      setState(() {
        _rows = rows;
        _parseError = null;
        _step = 1;
      });
    }
  }

  Future<void> _save() async {
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
              totalValue:
                  r.price != null ? r.price! * r.shares : null,
              filedAt: _filedAt,
              transactionDate: r.txDate,
              transactionType: r.txType,
              notes: 'Form 4 · ${_codeDesc(r.rawCode)}',
            ))
        .toList();

    await ref
        .read(tickerProfileNotifierProvider.notifier)
        .addInsiderBuys(widget.symbol, buys);
    if (mounted) Navigator.pop(context);
  }

  // ── Helpers ─────────────────────────────────────────────────────────────────

  Future<void> _pickFiledAt() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _filedAt,
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
    );
    if (picked != null) setState(() => _filedAt = picked);
  }

  String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  String _fmtShares(int n) => n.toString().replaceAllMapped(
        RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
        (m) => '${m[1]},',
      );

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
      child: _step == 0 ? _buildPasteStep() : _buildPreviewStep(),
    );
  }

  Widget _buildPasteStep() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Import Form 4 — ${widget.symbol}',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'Copy the full text from SEC EDGAR and paste below.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 16),
        InkWell(
          onTap: _pickFiledAt,
          child: InputDecorator(
            decoration: const InputDecoration(labelText: 'SEC Filing Date'),
            child: Text(_fmt(_filedAt)),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _pasteCtrl,
          maxLines: 12,
          decoration: const InputDecoration(
            labelText: 'Paste Form 4 text',
            alignLabelWithHint: true,
            hintText:
                'Paste the full text from the SEC EDGAR Form 4 page…',
          ),
        ),
        if (_parseError != null) ...[
          const SizedBox(height: 8),
          Text(
            _parseError!,
            style: TextStyle(
              color: Theme.of(context).colorScheme.error,
              fontSize: 12,
            ),
          ),
        ],
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _doParse,
          child: const Text('Parse Transactions'),
        ),
      ],
    );
  }

  Widget _buildPreviewStep() {
    final selectedCount = _rows.where((r) => r.selected).length;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back),
              padding: EdgeInsets.zero,
              onPressed: () => setState(() => _step = 0),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                '${_rows.length} transaction${_rows.length == 1 ? '' : 's'} · $_parsedTicker',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          ],
        ),
        Text(
          '$_parsedName · Filed ${_fmt(_filedAt)}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        ..._rows.asMap().entries.map((e) {
          final i = e.key;
          final r = e.value;
          final dispIcon = r.disposition == 'D' ? '▼' : '▲';
          final dispColor = r.disposition == 'D'
              ? Colors.redAccent
              : Colors.greenAccent;
          return CheckboxListTile(
            value: r.selected,
            onChanged: (v) =>
                setState(() => _rows[i].selected = v ?? false),
            title: Row(
              children: [
                Text(
                  dispIcon,
                  style: TextStyle(color: dispColor, fontSize: 13),
                ),
                const SizedBox(width: 4),
                Text(
                  '${_fmtShares(r.shares)} sh  ·  ${_codeDesc(r.rawCode)}',
                  style: const TextStyle(fontSize: 13),
                ),
              ],
            ),
            subtitle: Text(
              '${_fmt(r.txDate)}${r.price != null ? '  ·  \$${r.price!.toStringAsFixed(4).replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '')}' : ''}',
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
