// =============================================================================
// features/ticker_profile/widgets/fetch_dtes_sheet.dart
// =============================================================================
// Bottom sheet: let the user pick available expiration dates for a ticker,
// then trigger a high-strikeCount fetch that writes to all Supabase tables.
//
// Flow:
//   1. Load available expirations from a cheap strikeCount=1 chain call
//   2. User selects one or more expiration dates
//   3. Tap "Fetch" → POST /fetch/ticker-dtes → ~10-30s pipeline run
//   4. On success: show per-table result summary and close
// =============================================================================
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme.dart';
import '../../../services/schwab/schwab_models.dart';
import '../../../services/schwab/schwab_providers.dart';
import '../../../services/python_api/python_api_client.dart';
import '../../../features/auth/providers/auth_provider.dart';
import '../../greek_grid/providers/greek_grid_providers.dart';

class FetchDtesSheet extends ConsumerStatefulWidget {
  final String symbol;
  final VoidCallback? onFetchComplete;
  const FetchDtesSheet({super.key, required this.symbol, this.onFetchComplete});

  @override
  ConsumerState<FetchDtesSheet> createState() => _FetchDtesSheetState();
}

class _FetchDtesSheetState extends ConsumerState<FetchDtesSheet> {
  final Set<String> _selected = {};
  bool _fetching = false;
  String? _errorMessage;
  Map<String, String>? _resultSummary;

  OptionsChainParams get _expiryListParams => OptionsChainParams(
        symbol:      widget.symbol,
        strikeCount: 1,
      );

  Future<void> _runFetch(List<SchwabOptionsExpiration> expirations) async {
    final userId = ref.read(supabaseClientProvider).auth.currentUser?.id;
    if (userId == null) return;

    final selectedExps = expirations
        .where((e) => _selected.contains(e.expirationDate))
        .map((e) => e.expirationDate)
        .toList();
    if (selectedExps.isEmpty) return;

    setState(() {
      _fetching      = true;
      _errorMessage  = null;
      _resultSummary = null;
    });

    try {
      final result = await PythonApiClient.fetchTickerDtes(
        ticker:          widget.symbol,
        userId:          userId,
        expirationDates: selectedExps,
      );

      // Invalidate providers so the profile refreshes with new data
      ref.invalidate(greekGridProvider(widget.symbol));
      widget.onFetchComplete?.call();

      final raw = result['results'] as Map<String, dynamic>? ?? {};
      setState(() {
        _fetching      = false;
        _resultSummary = raw.map((k, v) => MapEntry(k, v.toString()));
      });
    } on PythonApiException catch (e) {
      setState(() {
        _fetching     = false;
        _errorMessage = e.message;
      });
    } catch (e) {
      setState(() {
        _fetching     = false;
        _errorMessage = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final chainAsync = ref.watch(schwabOptionsChainProvider(_expiryListParams));

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header
            Row(
              children: [
                const Icon(Icons.download_for_offline_outlined,
                    color: AppTheme.profitColor),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Fetch Options Snapshot',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Text(
                        widget.symbol,
                        style: const TextStyle(
                            color: AppTheme.neutralColor, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              'Select expiration dates to fetch at full strike depth (100 strikes). '
              'Data writes to all snapshot tables.',
              style: TextStyle(color: AppTheme.neutralColor, fontSize: 12, height: 1.4),
            ),
            const SizedBox(height: 16),

            // Expiry list or result summary
            if (_resultSummary != null)
              _ResultSummary(results: _resultSummary!)
            else
              chainAsync.when(
                loading: () => const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(child: CircularProgressIndicator()),
                ),
                error: (e, _) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Text('Could not load expirations: $e',
                      style: const TextStyle(color: AppTheme.lossColor)),
                ),
                data: (chain) {
                  if (chain == null || chain.expirations.isEmpty) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: Text('No expirations available',
                          style: TextStyle(color: AppTheme.neutralColor)),
                    );
                  }
                  return _ExpiryList(
                    expirations: chain.expirations,
                    selected:    _selected,
                    onToggle:    (date) => setState(() {
                      _selected.contains(date)
                          ? _selected.remove(date)
                          : _selected.add(date);
                    }),
                  );
                },
              ),

            if (_errorMessage != null) ...[
              const SizedBox(height: 12),
              Text(
                _errorMessage!,
                style: const TextStyle(color: AppTheme.lossColor, fontSize: 12),
              ),
            ],

            const SizedBox(height: 16),

            // Action button
            if (_resultSummary != null)
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Done'),
              )
            else
              chainAsync.whenOrNull(
                data: (chain) => FilledButton(
                  onPressed: (_selected.isEmpty || _fetching || chain == null)
                      ? null
                      : () => _runFetch(chain.expirations),
                  child: _fetching
                      ? const SizedBox(
                          height: 18,
                          width:  18,
                          child:  CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(
                          'Fetch ${_selected.length} expiration${_selected.length == 1 ? '' : 's'}',
                        ),
                ),
              ) ??
              const SizedBox.shrink(),
          ],
        ),
      ),
    );
  }
}

// ── Expiry list ───────────────────────────────────────────────────────────────

class _ExpiryList extends StatelessWidget {
  final List<SchwabOptionsExpiration> expirations;
  final Set<String> selected;
  final ValueChanged<String> onToggle;

  const _ExpiryList({
    required this.expirations,
    required this.selected,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 320),
      child: ListView.builder(
        shrinkWrap: true,
        itemCount: expirations.length,
        itemBuilder: (_, i) {
          final exp       = expirations[i];
          final isSelected = selected.contains(exp.expirationDate);
          return InkWell(
            onTap: () => onToggle(exp.expirationDate),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
              child: Row(
                children: [
                  Checkbox(
                    value:    isSelected,
                    onChanged: (_) => onToggle(exp.expirationDate),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    exp.expirationDate,
                    style: TextStyle(
                      fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                  const SizedBox(width: 8),
                  _DteBadge(dte: exp.dte),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _DteBadge extends StatelessWidget {
  final int dte;
  const _DteBadge({required this.dte});

  Color get _color {
    if (dte <= 7)  return AppTheme.lossColor;
    if (dte <= 30) return const Color(0xFFFFAB40);
    return AppTheme.neutralColor;
  }

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color:        _color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(4),
          border:       Border.all(color: _color.withValues(alpha: 0.35)),
        ),
        child: Text(
          '${dte}d',
          style: TextStyle(color: _color, fontSize: 10, fontWeight: FontWeight.w700),
        ),
      );
}

// ── Result summary ────────────────────────────────────────────────────────────

class _ResultSummary extends StatelessWidget {
  final Map<String, String> results;
  const _ResultSummary({required this.results});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Fetch complete',
          style: TextStyle(
            color:      AppTheme.profitColor,
            fontWeight: FontWeight.w700,
            fontSize:   14,
          ),
        ),
        const SizedBox(height: 10),
        ...results.entries.map((e) {
          final isOk  = e.value.startsWith('ok');
          final color = isOk ? AppTheme.profitColor : AppTheme.lossColor;
          final icon  = isOk ? Icons.check_circle_outline : Icons.error_outline;
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                Icon(icon, size: 14, color: color),
                const SizedBox(width: 6),
                Text(
                  e.key.replaceAll('_', ' '),
                  style: const TextStyle(fontSize: 13),
                ),
                const Spacer(),
                Text(
                  e.value,
                  style: TextStyle(color: color, fontSize: 12),
                ),
              ],
            ),
          );
        }),
      ],
    );
  }
}
