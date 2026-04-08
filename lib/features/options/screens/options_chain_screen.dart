// =============================================================================
// features/options/screens/options_chain_screen.dart
// Live options chain with scoring engine.
// Route: /ticker/:symbol/chains  (pushed from TickerProfileScreen)
// =============================================================================
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme.dart';
import '../../../services/kalshi/kalshi_providers.dart';
import '../../../services/schwab/schwab_models.dart';
import '../../../services/schwab/schwab_providers.dart';
import '../services/option_scoring_engine.dart';
import '../widgets/option_score_sheet.dart';

class OptionsChainScreen extends ConsumerStatefulWidget {
  final String symbol;
  const OptionsChainScreen({super.key, required this.symbol});

  @override
  ConsumerState<OptionsChainScreen> createState() => _OptionsChainScreenState();
}

class _OptionsChainScreenState extends ConsumerState<OptionsChainScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabs;
  int _strikeCount = 10;
  int _selectedExp = 0;
  bool _hasAutoSelected = false;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _tabs.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  OptionsChainParams get _params => OptionsChainParams(
        symbol:      widget.symbol,
        contractType: 'ALL',
        strikeCount:  _strikeCount,
      );

  @override
  Widget build(BuildContext context) {
    final chainAsync = ref.watch(schwabOptionsChainProvider(_params));

    return Scaffold(
      appBar: AppBar(
        title: chainAsync.when(
          data: (chain) => chain == null
              ? Text('${widget.symbol} Options')
              : Row(children: [
                  Text('${widget.symbol} Options'),
                  const SizedBox(width: 10),
                  Text(
                    '\$${chain.underlyingPrice.toStringAsFixed(2)}',
                    style: const TextStyle(
                      color:    AppTheme.profitColor,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ]),
          loading: () => Text('${widget.symbol} Options'),
          error:   (_, _) => Text('${widget.symbol} Options'),
        ),
        bottom: TabBar(
          controller: _tabs,
          indicatorColor: AppTheme.profitColor,
          labelColor:     AppTheme.profitColor,
          unselectedLabelColor: AppTheme.neutralColor,
          tabs: const [
            Tab(text: 'CALLS'),
            Tab(text: 'PUTS'),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/ticker/${widget.symbol}/chains/wizard'),
        backgroundColor: AppTheme.profitColor,
        foregroundColor: Colors.black,
        icon:  const Icon(Icons.auto_awesome),
        label: const Text('Analyze', style: TextStyle(fontWeight: FontWeight.w700)),
      ),
      body: chainAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error:   (e, _) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: AppTheme.lossColor, size: 40),
              const SizedBox(height: 12),
              Text('$e', style: const TextStyle(color: AppTheme.neutralColor),
                  textAlign: TextAlign.center),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () => ref.invalidate(schwabOptionsChainProvider(_params)),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
        data: (chain) {
          if (chain == null || chain.expirations.isEmpty) {
            return const Center(
              child: Text('No chain data available',
                  style: TextStyle(color: AppTheme.neutralColor)),
            );
          }

          // Auto-select the expiration closest to 30 DTE on first load only
          if (!_hasAutoSelected) {
            _hasAutoSelected = true;
            int bestIdx = 0;
            int bestDist = 999;
            for (var i = 0; i < chain.expirations.length; i++) {
              final dist = (chain.expirations[i].dte - 30).abs();
              if (dist < bestDist) { bestDist = dist; bestIdx = i; }
            }
            _selectedExp = bestIdx;
          }

          final exp = chain.expirations[_selectedExp];

          return Column(
            children: [
              // ── Controls bar ────────────────────────────────────────────
              _ControlsBar(
                chain:          chain,
                selectedExp:    _selectedExp,
                strikeCount:    _strikeCount,
                onExpChanged:   (i) => setState(() => _selectedExp = i),
                onCountChanged: (v) => setState(() => _strikeCount = v),
                onRefresh:      () => ref.invalidate(schwabOptionsChainProvider(_params)),
              ),

              // ── Kalshi event overlay ─────────────────────────────────────
              // Shows any Kalshi events that close before the selected
              // expiration date — flagged as High Volatility Events.
              _KalshiEventBanner(expirationDateStr: exp.expirationDate),

              // ── Chain table ──────────────────────────────────────────────
              Expanded(
                child: TabBarView(
                  controller: _tabs,
                  children: [
                    _ChainTable(
                      contracts:       exp.calls,
                      underlyingPrice: chain.underlyingPrice,
                      isCall:          true,
                    ),
                    _ChainTable(
                      contracts:       exp.puts,
                      underlyingPrice: chain.underlyingPrice,
                      isCall:          false,
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ── Controls bar ──────────────────────────────────────────────────────────────

class _ControlsBar extends StatelessWidget {
  final SchwabOptionsChain chain;
  final int    selectedExp;
  final int    strikeCount;
  final void Function(int)  onExpChanged;
  final void Function(int)  onCountChanged;
  final VoidCallback        onRefresh;

  const _ControlsBar({
    required this.chain,
    required this.selectedExp,
    required this.strikeCount,
    required this.onExpChanged,
    required this.onCountChanged,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.elevatedColor,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          // Expiration picker
          Expanded(
            child: SizedBox(
              height: 34,
              child: ListView.separated(
                scrollDirection:  Axis.horizontal,
                itemCount:        chain.expirations.length,
                separatorBuilder: (_, _) => const SizedBox(width: 6),
                itemBuilder: (_, i) {
                  final exp      = chain.expirations[i];
                  final selected = i == selectedExp;
                  final dteColor = exp.dte == 0
                      ? AppTheme.lossColor
                      : exp.dte <= 7
                          ? AppTheme.lossColor
                          : exp.dte <= 45
                              ? AppTheme.profitColor
                              : AppTheme.neutralColor;
                  return GestureDetector(
                    onTap: () => onExpChanged(i),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: selected
                            ? AppTheme.profitColor.withValues(alpha: 0.15)
                            : AppTheme.cardColor,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: selected
                              ? AppTheme.profitColor
                              : AppTheme.borderColor.withValues(alpha: 0.4),
                        ),
                      ),
                      child: Text(
                        '${exp.expirationDate.substring(5)}  ${exp.dte}d',
                        style: TextStyle(
                          color: selected ? AppTheme.profitColor : dteColor,
                          fontSize:   11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          const SizedBox(width: 8),

          // Strike count
          PopupMenuButton<int>(
            initialValue: strikeCount,
            color:        AppTheme.elevatedColor,
            tooltip:      'Strikes',
            onSelected:   onCountChanged,
            itemBuilder:  (_) => [5, 10, 15, 20]
                .map((n) => PopupMenuItem(value: n, child: Text('$n strikes')))
                .toList(),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color:        AppTheme.cardColor,
                borderRadius: BorderRadius.circular(8),
                border:       Border.all(
                    color: AppTheme.borderColor.withValues(alpha: 0.4)),
              ),
              child: Row(children: [
                Text('±$strikeCount',
                    style: const TextStyle(
                        color: AppTheme.neutralColor, fontSize: 12)),
                const SizedBox(width: 2),
                const Icon(Icons.expand_more,
                    color: AppTheme.neutralColor, size: 14),
              ]),
            ),
          ),
          const SizedBox(width: 6),

          // Refresh
          GestureDetector(
            onTap: onRefresh,
            child: Container(
              padding:    const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color:        AppTheme.cardColor,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.refresh_rounded,
                  color: AppTheme.neutralColor, size: 18),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Chain table ───────────────────────────────────────────────────────────────

class _ChainTable extends StatelessWidget {
  final List<SchwabOptionContract> contracts;
  final double underlyingPrice;
  final bool   isCall;

  const _ChainTable({
    required this.contracts,
    required this.underlyingPrice,
    required this.isCall,
  });

  @override
  Widget build(BuildContext context) {
    if (contracts.isEmpty) {
      return const Center(
        child: Text('No contracts', style: TextStyle(color: AppTheme.neutralColor)),
      );
    }

    return Column(
      children: [
        // Header row
        Container(
          color:   AppTheme.elevatedColor,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: const Row(
            children: [
              _Hdr('Score', flex: 2),
              _Hdr('Strike', flex: 2),
              _Hdr('Bid', flex: 2),
              _Hdr('Ask', flex: 2),
              _Hdr('Delta', flex: 2),
              _Hdr('IV%', flex: 2),
              _Hdr('OI', flex: 2),
              _Hdr('DTE', flex: 1),
            ],
          ),
        ),

        // Contracts
        Expanded(
          child: ListView.builder(
            itemCount: contracts.length,
            itemBuilder: (ctx, i) => _ContractRow(
              contract:        contracts[i],
              underlyingPrice: underlyingPrice,
              isCall:          isCall,
            ),
          ),
        ),
      ],
    );
  }
}

class _Hdr extends StatelessWidget {
  final String text;
  final int    flex;
  const _Hdr(this.text, {required this.flex});

  @override
  Widget build(BuildContext context) => Expanded(
        flex: flex,
        child: Text(
          text,
          style: const TextStyle(
            color:      AppTheme.neutralColor,
            fontSize:   10,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
}

// ── Single contract row ───────────────────────────────────────────────────────

class _ContractRow extends StatelessWidget {
  final SchwabOptionContract contract;
  final double underlyingPrice;
  final bool   isCall;

  const _ContractRow({
    required this.contract,
    required this.underlyingPrice,
    required this.isCall,
  });

  @override
  Widget build(BuildContext context) {
    final score   = OptionScoringEngine.score(contract, underlyingPrice);
    final isAtm   = (contract.strikePrice - underlyingPrice).abs() < 1.0;
    final isItm   = contract.inTheMoney;
    final accent  = isCall ? AppTheme.profitColor : AppTheme.lossColor;

    Color rowBg = Colors.transparent;
    if (isAtm) {
      rowBg = AppTheme.borderColor.withValues(alpha: 0.15);
    } else if (isItm) {
      rowBg = accent.withValues(alpha: 0.05);
    }

    return GestureDetector(
      onTap: () => showModalBottomSheet(
        context:        context,
        isScrollControlled: true,
        backgroundColor:    Colors.transparent,
        builder: (_) => OptionScoreSheet(
          contract:        contract,
          underlyingPrice: underlyingPrice,
        ),
      ),
      child: Container(
        color:   rowBg,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            // Score pill
            Expanded(
              flex: 2,
              child: _ScorePill(score: score),
            ),

            // Strike
            Expanded(
              flex: 2,
              child: Text(
                '\$${contract.strikePrice.toStringAsFixed(0)}',
                style: TextStyle(
                  color: isAtm
                      ? Colors.white
                      : isItm
                          ? accent.withValues(alpha: 0.9)
                          : AppTheme.neutralColor,
                  fontWeight:
                      isAtm ? FontWeight.w800 : FontWeight.w500,
                  fontSize: 13,
                ),
              ),
            ),

            // Bid
            Expanded(
              flex: 2,
              child: Text(
                contract.bid.toStringAsFixed(2),
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),

            // Ask
            Expanded(
              flex: 2,
              child: Text(
                contract.ask.toStringAsFixed(2),
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),

            // Delta
            Expanded(
              flex: 2,
              child: Text(
                contract.delta.toStringAsFixed(2),
                style: TextStyle(
                  color: _deltaColor(contract.delta.abs()),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),

            // IV
            Expanded(
              flex: 2,
              child: Text(
                '${contract.impliedVolatility.toStringAsFixed(0)}%',
                style: const TextStyle(color: AppTheme.neutralColor, fontSize: 12),
              ),
            ),

            // OI
            Expanded(
              flex: 2,
              child: Text(
                _fmtInt(contract.openInterest),
                style: const TextStyle(color: AppTheme.neutralColor, fontSize: 11),
              ),
            ),

            // DTE
            Expanded(
              flex: 1,
              child: Text(
                '${contract.daysToExpiration}',
                style: TextStyle(
                  color: contract.daysToExpiration <= 7
                      ? AppTheme.lossColor
                      : AppTheme.neutralColor,
                  fontSize: 11,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Color _deltaColor(double abs) {
    if (abs >= 0.30 && abs <= 0.50) return AppTheme.profitColor;
    if (abs >= 0.20 && abs <= 0.60) return const Color(0xFFFBBF24);
    return AppTheme.neutralColor;
  }

  static String _fmtInt(int n) =>
      n >= 1000 ? '${(n / 1000).toStringAsFixed(1)}k' : '$n';
}

// ── Kalshi event overlay ──────────────────────────────────────────────────────
// Shows a horizontal scroll of Kalshi events whose close_time falls before
// the selected option expiration. Each chip displays the event title and the
// leading market's yes probability. Hidden when there are no relevant events.

class _KalshiEventBanner extends ConsumerWidget {
  final String expirationDateStr; // "YYYY-MM-DD" from SchwabExpiration

  const _KalshiEventBanner({required this.expirationDateStr});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final expDate = DateTime.tryParse(expirationDateStr);
    if (expDate == null) return const SizedBox.shrink();

    final async = ref.watch(kalshiEventsForExpirationProvider(expDate));

    return async.when(
      loading: () => const SizedBox.shrink(),
      error:   (_, _) => const SizedBox.shrink(),
      data: (events) {
        if (events.isEmpty) return const SizedBox.shrink();
        return Container(
          color:  const Color(0xFFF59E0B).withValues(alpha: 0.07),
          padding: const EdgeInsets.fromLTRB(12, 7, 12, 7),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const Icon(Icons.bolt_rounded,
                    color: Color(0xFFF59E0B), size: 13),
                const SizedBox(width: 4),
                Text(
                  'HIGH VOLATILITY EVENTS BEFORE EXPIRY',
                  style: TextStyle(
                    color:      const Color(0xFFF59E0B).withValues(alpha: 0.9),
                    fontSize:   10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                  ),
                ),
              ]),
              const SizedBox(height: 6),
              SizedBox(
                height: 36,
                child: ListView.separated(
                  scrollDirection:  Axis.horizontal,
                  itemCount:        events.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 6),
                  itemBuilder: (_, i) {
                    final event   = events[i];
                    final leading = event.leadingMarket;
                    final prob    = leading?.yesProbability;
                    final label   = prob != null
                        ? '${(prob * 100).toStringAsFixed(0)}% — ${event.title}'
                        : event.title;
                    return Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF59E0B).withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: const Color(0xFFF59E0B).withValues(alpha: 0.45),
                        ),
                      ),
                      child: Text(
                        label,
                        style: const TextStyle(
                          color:      Color(0xFFF59E0B),
                          fontSize:   12,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines:  1,
                        overflow:  TextOverflow.ellipsis,
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ── Score pill ────────────────────────────────────────────────────────────────

class _ScorePill extends StatelessWidget {
  final OptionScore score;
  const _ScorePill({required this.score});

  @override
  Widget build(BuildContext context) {
    final color = switch (score.grade) {
      'A' => AppTheme.profitColor,
      'B' => const Color(0xFF60A5FA),
      'C' => const Color(0xFFFBBF24),
      _   => AppTheme.lossColor,
    };
    return Container(
      padding:    const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color:        color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
        border:       Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        '${score.total} ${score.grade}',
        style: TextStyle(
          color:      color,
          fontSize:   11,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}
