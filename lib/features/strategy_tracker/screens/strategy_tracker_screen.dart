// =============================================================================
// features/strategy_tracker/screens/strategy_tracker_screen.dart
// =============================================================================
// Main strategy list screen.
//
// Widgets:
//   StrategyTrackerScreen — ConsumerWidget; list of all strategy cards + FAB
//   _SummaryHeader        — total strategies, avg win rate, total P&L
//   _StrategyCard         — one card per setup; tap → detail; kebab → edit/delete
//   _RecentDots           — last 10 scored trades visualised as coloured circles
//   _StatusBadge          — HOT / WARM / COLD / DEAD / RECOVERING chip
//   _CriteriaChips        — first few criteria labels as compact chips
//   _EmptyState           — shown when no strategies exist yet
// =============================================================================
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme.dart';
import '../../../core/widgets/app_menu_button.dart';
import '../models/strategy_models.dart';
import '../providers/strategy_tracker_provider.dart';
import '../widgets/add_strategy_sheet.dart';
import 'mu_playbook_screen.dart';

// ── Shared sheet launcher ─────────────────────────────────────────────────────

void _showStrategySheet(BuildContext context, {StrategySetup? initialSetup}) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => AddStrategySheet(initialSetup: initialSetup),
  );
}

// ── Main screen ───────────────────────────────────────────────────────────────

class StrategyTrackerScreen extends ConsumerWidget {
  const StrategyTrackerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final setupsAsync = ref.watch(strategyTrackerProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Strategy Tracker'),
        actions: const [AppMenuButton()],
      ),
      body: setupsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error:   (e, _) => Center(
          child: Text('Error: $e',
              style: const TextStyle(color: AppTheme.lossColor)),
        ),
        data: (setups) {
          if (setups.isEmpty) return const _EmptyState();
          return ListView(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 100),
            children: [
              Card(
                child: ListTile(
                  leading: const Icon(Icons.auto_graph),
                  title: const Text('MU Composite Playbook',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: const Text(
                      'Backtested rules, live position, options reality'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const MuPlaybookScreen())),
                ),
              ),
              const SizedBox(height: 12),
              _SummaryHeader(setups: setups),
              const SizedBox(height: 16),
              for (final s in setups) _StrategyCard(setup: s),
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showStrategySheet(context),
        icon: const Icon(Icons.add),
        label: const Text('New Strategy'),
        backgroundColor: AppTheme.profitColor,
        foregroundColor: Colors.black,
      ),
    );
  }
}

// ── Summary header ─────────────────────────────────────────────────────────────

class _SummaryHeader extends StatelessWidget {
  final List<StrategySetup> setups;
  const _SummaryHeader({required this.setups});

  @override
  Widget build(BuildContext context) {
    final scored   = setups.where((s) => s.totalScored > 0);
    final avgWr    = scored.isEmpty
        ? 0.0
        : scored.map((s) => s.winRate).reduce((a, b) => a + b) / scored.length;
    final totalPnl = setups.fold(0.0, (sum, s) => sum + s.totalPnl);
    final pnlColor = totalPnl >= 0 ? AppTheme.profitColor : AppTheme.lossColor;

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            _Stat('${setups.length}',    'Strategies'),
            _Divider(),
            _Stat('${(avgWr * 100).toStringAsFixed(0)}%', 'Avg Win Rate'),
            _Divider(),
            _Stat(
              '${totalPnl >= 0 ? '+' : ''}\$${totalPnl.abs() >= 1000 ? '${(totalPnl / 1000).toStringAsFixed(1)}k' : totalPnl.toStringAsFixed(0)}',
              'Total P&L',
              valueColor: pnlColor,
            ),
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final String  value;
  final String  label;
  final Color?  valueColor;
  const _Stat(this.value, this.label, {this.valueColor});

  @override
  Widget build(BuildContext context) => Expanded(
        child: Column(
          children: [
            Text(
              value,
              style: TextStyle(
                fontSize:   20,
                fontWeight: FontWeight.w800,
                color:      valueColor ?? Colors.white,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: const TextStyle(
                  color: AppTheme.neutralColor, fontSize: 11),
            ),
          ],
        ),
      );
}

class _Divider extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Container(
        width: 1,
        height: 36,
        color: AppTheme.borderColor.withValues(alpha: 0.4),
      );
}

// ── Strategy card ─────────────────────────────────────────────────────────────

class _StrategyCard extends ConsumerWidget {
  final StrategySetup setup;
  const _StrategyCard({required this.setup});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wr      = setup.winRate;
    final wrColor = wr >= 0.60
        ? AppTheme.profitColor
        : wr >= 0.40
            ? const Color(0xFFFBBF24)
            : AppTheme.lossColor;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: setup.status.color.withValues(alpha: 0.35),
            width: 1.5,
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => context.push('/strategy-tracker/${setup.id}'),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Row 1: name + status badge + kebab menu
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        setup.name,
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize:   16,
                          color:      Colors.white,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    _StatusBadge(setup.status),
                    _CardMenu(setup: setup),
                  ],
                ),
                const SizedBox(height: 8),

                // Row 2: win rate + counts + profit factor
                Row(
                  children: [
                    Text(
                      setup.totalScored == 0
                          ? '—'
                          : '${(wr * 100).toStringAsFixed(0)}%',
                      style: TextStyle(
                        fontSize:   22,
                        fontWeight: FontWeight.w900,
                        color:      setup.totalScored == 0
                            ? AppTheme.neutralColor
                            : wrColor,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'WR',
                      style: TextStyle(
                        fontSize:   11,
                        fontWeight: FontWeight.w700,
                        color:      wrColor.withValues(alpha: 0.7),
                      ),
                    ),
                    const SizedBox(width: 16),
                    _MiniStat(
                      '${setup.wins}W / ${setup.losses}L',
                      '${setup.linkedTrades.length} trades',
                    ),
                    if (setup.totalScored > 0) ...[
                      const SizedBox(width: 16),
                      _MiniStat(
                        setup.profitFactor >= 999
                            ? '∞'
                            : setup.profitFactor.toStringAsFixed(2),
                        'PF',
                      ),
                      const SizedBox(width: 16),
                      _MiniStat(
                        '${setup.expectancy >= 0 ? '+' : ''}\$${setup.expectancy.toStringAsFixed(0)}',
                        'Expect.',
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 10),

                // Row 3: recent result dots
                if (setup.scoredTrades.isNotEmpty) ...[
                  _RecentDots(trades: setup.scoredTrades),
                  const SizedBox(height: 10),
                ],

                // Row 4: criteria chips
                if (setup.hasCriteria)
                  _CriteriaChips(labels: setup.allCriteriaLabels),

                // Row 5: target area chips
                if (setup.hasTargets) ...[
                  if (setup.hasCriteria) const SizedBox(height: 5),
                  _TargetAreaChips(areas: setup.targetAreas),
                ],

                // Tags
                if (setup.tags.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: [
                      for (final tag in setup.tags)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppTheme.elevatedColor,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            tag,
                            style: const TextStyle(
                              color:    AppTheme.neutralColor,
                              fontSize: 10,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

}

// ── Card kebab menu (Edit / Delete) ───────────────────────────────────────────

class _CardMenu extends ConsumerWidget {
  final StrategySetup setup;
  const _CardMenu({required this.setup});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<_CardAction>(
      icon: const Icon(
        Icons.more_vert_rounded,
        size:  18,
        color: AppTheme.neutralColor,
      ),
      color:  AppTheme.elevatedColor,
      shape:  RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      onSelected: (action) {
        if (action == _CardAction.edit) {
          _showStrategySheet(context, initialSetup: setup);
        } else {
          _confirmDelete(context, ref);
        }
      },
      itemBuilder: (_) => [
        const PopupMenuItem(
          value: _CardAction.edit,
          child: Row(
            children: [
              Icon(Icons.edit_rounded, size: 16, color: Colors.white70),
              SizedBox(width: 10),
              Text('Edit', style: TextStyle(color: Colors.white)),
            ],
          ),
        ),
        const PopupMenuItem(
          value: _CardAction.delete,
          child: Row(
            children: [
              Icon(Icons.delete_outline_rounded,
                  size: 16, color: AppTheme.lossColor),
              SizedBox(width: 10),
              Text('Delete',
                  style: TextStyle(color: AppTheme.lossColor)),
            ],
          ),
        ),
      ],
    );
  }

  void _confirmDelete(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.elevatedColor,
        title: const Text('Delete Strategy?'),
        content: Text(
          'This will delete "${setup.name}" and untag all linked trades. '
          'The trades themselves are kept.',
          style: const TextStyle(color: AppTheme.neutralColor),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              await ref
                  .read(strategyTrackerProvider.notifier)
                  .deleteSetup(setup.id);
            },
            style: TextButton.styleFrom(
                foregroundColor: AppTheme.lossColor),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }
}

enum _CardAction { edit, delete }

class _MiniStat extends StatelessWidget {
  final String value;
  final String label;
  const _MiniStat(this.value, this.label);

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: const TextStyle(
              fontSize:   13,
              fontWeight: FontWeight.w700,
              color:      Colors.white,
            ),
          ),
          Text(
            label,
            style: const TextStyle(
              fontSize: 10,
              color:    AppTheme.neutralColor,
            ),
          ),
        ],
      );
}

// ── Recent result dots (last 10 scored trades, newest-right) ──────────────────

class _RecentDots extends StatelessWidget {
  final List<dynamic> trades; // List<Trade> but avoid tight coupling here
  const _RecentDots({required this.trades});

  @override
  Widget build(BuildContext context) {
    // scoredTrades arrive oldest-first; show last 10, newest on right
    final recent = trades.length > 10
        ? trades.sublist(trades.length - 10)
        : trades;

    return Row(
      children: [
        for (final t in recent)
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: _dot(t.realizedPnl as double?),
          ),
        const SizedBox(width: 4),
        const Text(
          '← oldest   newest →',
          style: TextStyle(color: AppTheme.neutralColor, fontSize: 9),
        ),
      ],
    );
  }

  Widget _dot(double? pnl) {
    final Color color;
    if (pnl == null) {
      color = AppTheme.neutralColor;
    } else if (pnl > 0) {
      color = AppTheme.profitColor;
    } else if (pnl < 0) {
      color = AppTheme.lossColor;
    } else {
      color = AppTheme.neutralColor;
    }

    return Container(
      width:  10,
      height: 10,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withValues(alpha: 0.85),
      ),
    );
  }
}

// ── Criteria chips (compact preview) ──────────────────────────────────────────

class _CriteriaChips extends StatelessWidget {
  final List<String> labels;
  const _CriteriaChips({required this.labels});

  @override
  Widget build(BuildContext context) {
    // Show first 4, then "+N more"
    final shown    = labels.take(4).toList();
    final overflow = labels.length - shown.length;

    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        for (final lbl in shown) _chip(lbl),
        if (overflow > 0) _chip('+$overflow more', muted: true),
      ],
    );
  }

  Widget _chip(String label, {bool muted = false}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: muted
              ? AppTheme.elevatedColor
              : AppTheme.profitColor.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(5),
          border: Border.all(
            color: muted
                ? AppTheme.borderColor.withValues(alpha: 0.3)
                : AppTheme.profitColor.withValues(alpha: 0.25),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize:   10,
            color:      muted ? AppTheme.neutralColor : AppTheme.profitColor,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
}

// ── Target area chips (compact, blue) ─────────────────────────────────────────

class _TargetAreaChips extends StatelessWidget {
  final List<TargetArea> areas;
  const _TargetAreaChips({required this.areas});

  static const _color = Color(0xFF60A5FA);

  @override
  Widget build(BuildContext context) {
    final shown    = areas.take(4).toList();
    final overflow = areas.length - shown.length;
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        for (final a in shown) _chip(a.label),
        if (overflow > 0) _chip('+$overflow more', muted: true),
      ],
    );
  }

  Widget _chip(String label, {bool muted = false}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: muted
              ? AppTheme.elevatedColor
              : _color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(5),
          border: Border.all(
            color: muted
                ? AppTheme.borderColor.withValues(alpha: 0.3)
                : _color.withValues(alpha: 0.30),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize:   10,
            fontWeight: FontWeight.w600,
            color:      muted ? AppTheme.neutralColor : _color,
          ),
        ),
      );
}

// ── Status badge ──────────────────────────────────────────────────────────────

class _StatusBadge extends StatelessWidget {
  final SetupStatus status;
  const _StatusBadge(this.status);

  @override
  Widget build(BuildContext context) {
    final color = status.color;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color:        color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
        border:       Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        status.label,
        style: TextStyle(
          fontSize:      10,
          fontWeight:    FontWeight.w800,
          color:         color,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

// ── Empty state ───────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.track_changes_rounded,
                  size: 64, color: AppTheme.neutralColor),
              const SizedBox(height: 16),
              const Text(
                'No strategies yet',
                style: TextStyle(
                  color:      Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize:   18,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Create a strategy to define your entry criteria,\n'
                'tag trades to it, and track win rate over time.',
                style:     TextStyle(color: AppTheme.neutralColor, fontSize: 13),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 28),
              ElevatedButton.icon(
                onPressed: () => _showStrategySheet(context),
                icon:  const Icon(Icons.add, size: 16),
                label: const Text('Create Strategy'),
              ),
            ],
          ),
        ),
      );
}
