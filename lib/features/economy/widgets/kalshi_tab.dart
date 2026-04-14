// =============================================================================
// features/economy/widgets/kalshi_tab.dart
// =============================================================================
// Kalshi tab for the Economy Pulse screen.
//
// Sections:
//  • Active Events — each event card shows the leading market's yes probability,
//    yes/no ask prices, and the event close time.
//  • Events are grouped by category (Economics, Politics, Sports, etc.).
//  • Pull-to-refresh re-fetches kalshiMacroEventsProvider.
// =============================================================================
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme.dart';
import '../../../services/kalshi/kalshi_models.dart';
import '../../../services/kalshi/kalshi_providers.dart';

class KalshiTab extends ConsumerWidget {
  const KalshiTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(kalshiMacroEventsProvider);

    return RefreshIndicator(
      color: AppTheme.profitColor,
      onRefresh: () async {
        ref.invalidate(kalshiMacroEventsProvider);
        await ref.read(kalshiMacroEventsProvider.future);
      },
      child: async.when(
        loading: () =>
            const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.wifi_off_outlined,
                  size: 24, color: AppTheme.neutralColor),
              const SizedBox(height: 12),
              Text('$e',
                  style:
                      const TextStyle(color: AppTheme.neutralColor),
                  textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => ref.invalidate(kalshiMacroEventsProvider),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
        data: (events) => _EventList(events: events),
      ),
    );
  }
}

// ── Event list (grouped by category) ─────────────────────────────────────────

class _EventList extends StatelessWidget {
  final List<KalshiEvent> events;
  const _EventList({required this.events});

  @override
  Widget build(BuildContext context) {
    if (events.isEmpty) {
      return const Center(
        child: Text('No active events',
            style: TextStyle(color: AppTheme.neutralColor)),
      );
    }

    // Group events by category; null category → "Other"
    final grouped = <String, List<KalshiEvent>>{};
    for (final e in events) {
      final cat = e.category ?? e.seriesTicker ?? 'Other';
      grouped.putIfAbsent(cat, () => []).add(e);
    }

    // Sort categories: Economics first, then alphabetical
    final categories = grouped.keys.toList()
      ..sort((a, b) {
        if (a == 'Economics') return -1;
        if (b == 'Economics') return 1;
        if (a == 'Politics') return -1;
        if (b == 'Politics') return 1;
        return a.compareTo(b);
      });

    return GridView.builder(
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        mainAxisSpacing: 6,
        crossAxisSpacing: 6,
        childAspectRatio: 1.2,
      ),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      itemCount: categories.fold<int>(0, (sum, cat) => sum + grouped[cat]!.length + 1),
      itemBuilder: (_, globalIdx) {
        // Flatten: category header + event cards
        int offset = 0;
        for (final cat in categories) {
          final items = grouped[cat]!;
          if (globalIdx == offset) {
            return _CategoryHeader(cat);
          }
          offset++;
          if (globalIdx < offset + items.length) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _EventCard(event: items[globalIdx - offset]),
                          );
          }
          offset += items.length;
        }
        return const SizedBox.shrink();
      },
    );
  }
}

// ── Category header ───────────────────────────────────────────────────────────

class _CategoryHeader extends StatelessWidget {
  final String category;
  const _CategoryHeader(this.category);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 16, 0, 8),
      child: Text(
        category.toUpperCase(),
        style: const TextStyle(
          color:      AppTheme.neutralColor,
          fontSize:   11,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}

// ── Event card ────────────────────────────────────────────────────────────────

class _EventCard extends StatelessWidget {
  final KalshiEvent event;
  const _EventCard({required this.event});

  @override
  Widget build(BuildContext context) {
    final leading = event.leadingMarket;
    final prob    = leading?.yesProbability;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color:        AppTheme.cardColor,
        borderRadius: BorderRadius.circular(10),
        border:       Border.all(color: AppTheme.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Title + close time
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  event.title,
                  style: const TextStyle(
                    fontSize:   13,
                    fontWeight: FontWeight.w600,
                    color:      Colors.white,
                  ),
                ),
              ),
              if (event.closeDateTime != null) ...[
                const SizedBox(width: 8),
                _CloseBadge(dt: event.closeDateTime!),
              ],
            ],
          ),

          if (leading != null) ...[
            const SizedBox(height: 12),
            // Probability bar + leading outcome
            _ProbabilityRow(market: leading, prob: prob),
            const SizedBox(height: 10),
            // Yes / No ask prices
            _MarketPriceRow(market: leading),
          ],

          // Additional markets (up to 3 more shown as smaller chips)
          if (event.markets.length > 1) ...[
            const SizedBox(height: 10),
            _OtherMarkets(
              markets: event.markets
                  .where((m) => m.ticker != leading?.ticker)
                  .take(3)
                  .toList(),
            ),
          ],
        ],
      ),
    );
  }
}

// ── Probability bar ───────────────────────────────────────────────────────────

class _ProbabilityRow extends StatelessWidget {
  final KalshiMarket market;
  final double? prob;
  const _ProbabilityRow({required this.market, required this.prob});

  @override
  Widget build(BuildContext context) {
    final pct = prob ?? 0.0;
    final color = pct >= 0.65
        ? AppTheme.profitColor
        : pct >= 0.40
            ? const Color(0xFFFBBF24)
            : AppTheme.lossColor;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                market.title,
                style: const TextStyle(
                    color: AppTheme.neutralColor, fontSize: 11),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${(pct * 100).toStringAsFixed(0)}% YES',
              style: TextStyle(
                color:      color,
                fontSize:   13,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value:            pct.clamp(0.0, 1.0),
            backgroundColor:  AppTheme.borderColor,
            valueColor:       AlwaysStoppedAnimation<Color>(color),
            minHeight:        6,
          ),
        ),
      ],
    );
  }
}

// ── Yes / No price row ────────────────────────────────────────────────────────

class _MarketPriceRow extends StatelessWidget {
  final KalshiMarket market;
  const _MarketPriceRow({required this.market});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _PriceChip(
          label: 'YES ask',
          value: market.yesAsk,
          color: AppTheme.profitColor,
        ),
        const SizedBox(width: 8),
        _PriceChip(
          label: 'NO ask',
          value: market.noAsk,
          color: AppTheme.lossColor,
        ),
        if (market.volume != null) ...[
          const Spacer(),
          Text(
            'Vol ${_fmtInt(market.volume!)}',
            style: const TextStyle(
                color: AppTheme.neutralColor, fontSize: 11),
          ),
        ],
      ],
    );
  }
}

class _PriceChip extends StatelessWidget {
  final String label;
  final double? value;
  final Color color;
  const _PriceChip(
      {required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    final display = value != null ? '${(value! * 100).toStringAsFixed(0)}¢' : '—';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color:        color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
        border:       Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        '$label $display',
        style: TextStyle(
          color:      color,
          fontSize:   11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

// ── Other markets (small chips for a binary/multi-outcome event) ──────────────

class _OtherMarkets extends StatelessWidget {
  final List<KalshiMarket> markets;
  const _OtherMarkets({required this.markets});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: markets.map((m) {
        final prob = m.yesProbability;
        final label = prob != null
            ? '${m.title}  ${(prob * 100).toStringAsFixed(0)}%'
            : m.title;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color:        AppTheme.elevatedColor,
            borderRadius: BorderRadius.circular(6),
            border:       Border.all(
                color: AppTheme.borderColor.withValues(alpha: 0.5)),
          ),
          child: Text(
            label,
            style: const TextStyle(
                color: AppTheme.neutralColor, fontSize: 11),
          ),
        );
      }).toList(),
    );
  }
}

// ── Close time badge ──────────────────────────────────────────────────────────

class _CloseBadge extends StatelessWidget {
  final DateTime dt;
  const _CloseBadge({required this.dt});

  @override
  Widget build(BuildContext context) {
    final now  = DateTime.now().toUtc();
    final diff = dt.difference(now);
    final label = diff.inDays > 0
        ? '${diff.inDays}d'
        : diff.inHours > 0
            ? '${diff.inHours}h'
            : '< 1h';

    final urgent = diff.inDays < 3;
    final color  = urgent ? const Color(0xFFF59E0B) : AppTheme.neutralColor;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color:        color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(5),
        border:       Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        'closes $label',
        style: TextStyle(
            color: color, fontSize: 10, fontWeight: FontWeight.w600),
      ),
    );
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

String _fmtInt(int n) =>
    n >= 1000 ? '${(n / 1000).toStringAsFixed(1)}k' : '$n';
