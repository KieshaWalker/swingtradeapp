// =============================================================================
// features/ticker_profile/screens/ticker_profile_cards.dart
// =============================================================================
// Card widgets used in the Overview, Levels and Timeline tabs:
//   EarningsDateCard, InsiderBuyCard, EarningsReactionCard, NoteCard,
//   SRLevelCard, TimelineEventTile
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme.dart';
import '../../../services/fmp/fmp_models.dart';
import '../models/ticker_profile_models.dart';
import '../providers/ticker_profile_notifier.dart';
import '../widgets/add_earnings_reaction_sheet.dart';

// ─── Earnings date card ───────────────────────────────────────────────────────

class EarningsDateCard extends StatelessWidget {
  final FmpEarningsDate earnings;
  const EarningsDateCard(this.earnings, {super.key});

  @override
  Widget build(BuildContext context) {
    final d = earnings.date;
    final label =
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const Icon(Icons.event, color: AppTheme.profitColor),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  if (earnings.timeLabel.isNotEmpty)
                    Text(earnings.timeLabel,
                        style: const TextStyle(
                            color: AppTheme.neutralColor, fontSize: 12)),
                  if (earnings.epsEstimated != null)
                    Text(
                        'EPS est. ${earnings.epsEstimated!.toStringAsFixed(2)}',
                        style: const TextStyle(
                            color: AppTheme.neutralColor, fontSize: 12)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Insider buy card ─────────────────────────────────────────────────────────

class InsiderBuyCard extends ConsumerWidget {
  final String symbol;
  final TickerInsiderBuy buy;
  const InsiderBuyCard({super.key, required this.symbol, required this.buy});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isBuy = buy.transactionType == InsiderTransactionType.purchase ||
        buy.transactionType == InsiderTransactionType.exercise;
    final isSell = buy.transactionType == InsiderTransactionType.sale ||
        buy.transactionType == InsiderTransactionType.taxWithholding;
    final iconColor = isBuy
        ? AppTheme.profitColor
        : isSell
            ? AppTheme.lossColor
            : AppTheme.neutralColor;
    final icon = isBuy
        ? Icons.trending_up
        : isSell
            ? Icons.trending_down
            : Icons.swap_horiz;
    final val = buy.totalValue != null
        ? ' · \$${(buy.totalValue! / 1000).toStringAsFixed(0)}k'
        : '';
    final dateStr =
        '${buy.filedAt.year}-${buy.filedAt.month.toString().padLeft(2, '0')}-${buy.filedAt.day.toString().padLeft(2, '0')}';
    return Card(
      child: ListTile(
        leading: Icon(icon, color: iconColor),
        title: Text(buy.insiderName),
        subtitle: Text(
            '${buy.transactionType.label} · ${buy.shares} sh$val · $dateStr'),
        trailing: IconButton(
          icon: const Icon(Icons.delete_outline,
              size: 18, color: AppTheme.neutralColor),
          onPressed: () async {
            await ref
                .read(tickerProfileNotifierProvider.notifier)
                .deleteInsiderBuy(buy.id, symbol);
          },
        ),
      ),
    );
  }
}

// ─── Earnings reaction card ───────────────────────────────────────────────────

class EarningsReactionCard extends ConsumerWidget {
  final String symbol;
  final TickerEarningsReaction reaction;
  const EarningsReactionCard(
      {super.key, required this.symbol, required this.reaction});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dir = reaction.direction ?? '';
    final dirColor = dir == 'up'
        ? AppTheme.profitColor
        : dir == 'down'
            ? AppTheme.lossColor
            : AppTheme.neutralColor;
    final movePctStr = reaction.movePct != null
        ? '${reaction.movePct! >= 0 ? '+' : ''}${reaction.movePct!.toStringAsFixed(1)}%'
        : '';

    return Card(
      child: ListTile(
        leading: Icon(
          dir == 'up'
              ? Icons.arrow_upward
              : dir == 'down'
                  ? Icons.arrow_downward
                  : Icons.remove,
          color: dirColor,
        ),
        title: Text(reaction.fiscalPeriod ??
            '${reaction.earningsDate.year}-${reaction.earningsDate.month.toString().padLeft(2, '0')}-${reaction.earningsDate.day.toString().padLeft(2, '0')}'),
        subtitle: Text([
          if (movePctStr.isNotEmpty) movePctStr,
          if (reaction.beat) 'Beat',
          if (reaction.epsActual != null)
            'EPS ${reaction.epsActual!.toStringAsFixed(2)}',
        ].join(' · ')),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.edit_outlined,
                  size: 18, color: AppTheme.neutralColor),
              onPressed: () => showModalBottomSheet(
                context: context,
                isScrollControlled: true,
                backgroundColor: AppTheme.elevatedColor,
                shape: const RoundedRectangleBorder(
                  borderRadius:
                      BorderRadius.vertical(top: Radius.circular(16)),
                ),
                builder: (_) => AddEarningsReactionSheet(
                    symbol: symbol, existing: reaction),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline,
                  size: 18, color: AppTheme.neutralColor),
              onPressed: () async {
                await ref
                    .read(tickerProfileNotifierProvider.notifier)
                    .deleteEarningsReaction(reaction.id, symbol);
              },
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Note card ────────────────────────────────────────────────────────────────

class NoteCard extends ConsumerWidget {
  final String symbol;
  final TickerProfileNote note;
  const NoteCard({super.key, required this.symbol, required this.note});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${note.createdAt.year}-${note.createdAt.month.toString().padLeft(2, '0')}-${note.createdAt.day.toString().padLeft(2, '0')}',
                    style: const TextStyle(
                        color: AppTheme.neutralColor, fontSize: 12),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline,
                      size: 18, color: AppTheme.neutralColor),
                  onPressed: () async {
                    await ref
                        .read(tickerProfileNotifierProvider.notifier)
                        .deleteNote(note.id, symbol);
                  },
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
            Text(note.body),
            if (note.tags.isNotEmpty)
              Wrap(
                spacing: 4,
                children: note.tags
                    .map((t) => Chip(
                          label: Text(t),
                          visualDensity: VisualDensity.compact,
                        ))
                    .toList(),
              ),
          ],
        ),
      ),
    );
  }
}

// ─── S/R level card ───────────────────────────────────────────────────────────

class SRLevelCard extends ConsumerWidget {
  final String symbol;
  final SupportResistanceLevel level;
  const SRLevelCard({super.key, required this.symbol, required this.level});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isSupport = level.levelType == SRLevelType.support;
    return Card(
      child: ListTile(
        leading: Icon(
          isSupport ? Icons.arrow_upward : Icons.arrow_downward,
          color:
              isSupport ? AppTheme.profitColor : AppTheme.lossColor,
        ),
        title: Text('\$${level.price.toStringAsFixed(2)}'
            '${level.label != null ? '  ·  ${level.label}' : ''}'),
        subtitle: Text([
          level.levelType.name,
          if (level.timeframe != null) level.timeframe!.label,
          if (!level.isActive) 'Invalidated',
        ].join(' · ')),
        trailing: level.isActive
            ? IconButton(
                icon: const Icon(Icons.check_circle_outline,
                    size: 18, color: AppTheme.neutralColor),
                tooltip: 'Invalidate level',
                onPressed: () async {
                  await ref
                      .read(tickerProfileNotifierProvider.notifier)
                      .invalidateSRLevel(level.id, symbol, null);
                },
              )
            : null,
      ),
    );
  }
}

// ─── Timeline event tile ──────────────────────────────────────────────────────

class TimelineEventTile extends StatelessWidget {
  final TickerTimelineEvent event;
  const TimelineEventTile({super.key, required this.event});

  Color _dotColor() => switch (event.type) {
        TimelineEventType.tradeClosed => event.trade?.isProfitable == true
            ? AppTheme.profitColor
            : AppTheme.lossColor,
        TimelineEventType.tradeOpened => AppTheme.neutralColor,
        TimelineEventType.note => const Color(0xFF7EC8E3),
        TimelineEventType.secFiling => const Color(0xFFFFD166),
        TimelineEventType.earningsReaction =>
          event.earningsReaction?.direction == 'up'
              ? AppTheme.profitColor
              : AppTheme.lossColor,
        TimelineEventType.insiderBuy => AppTheme.profitColor,
        TimelineEventType.srLevelAdded => const Color(0xFFBBABFF),
        TimelineEventType.srLevelInvalidated => AppTheme.neutralColor,
      };

  IconData _icon() => switch (event.type) {
        TimelineEventType.tradeOpened => Icons.open_in_new,
        TimelineEventType.tradeClosed => Icons.check_circle_outline,
        TimelineEventType.note => Icons.note_outlined,
        TimelineEventType.secFiling => Icons.description_outlined,
        TimelineEventType.earningsReaction => Icons.bar_chart,
        TimelineEventType.insiderBuy => Icons.trending_up,
        TimelineEventType.srLevelAdded => Icons.horizontal_rule,
        TimelineEventType.srLevelInvalidated => Icons.remove_circle_outline,
      };

  @override
  Widget build(BuildContext context) {
    final d = event.timestamp;
    final dateStr =
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: _dotColor().withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(_icon(), size: 16, color: _dotColor()),
              ),
              Container(
                  width: 2, height: 32, color: AppTheme.borderColor),
            ],
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(dateStr,
                    style: const TextStyle(
                        color: AppTheme.neutralColor, fontSize: 11)),
                const SizedBox(height: 2),
                Text(event.summary),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
