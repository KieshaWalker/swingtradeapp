// =============================================================================
// features/swing/screens/swing_screen.dart — Swing Setups screen
// =============================================================================
// Ranked view of swing_setups for the latest session.
//
// THERE IS NO BUY/SELL COLUMN, AND THAT IS DELIBERATE.
// The obvious design is a directional verdict per row. Measured over this
// universe (48 tickers, ~6 months, walk-forward), channel position on its own
// carried no reliable directional edge — pooled it looked like momentum, but
// that was two outliers, and per-ticker it split 12 momentum / 16 mean-reverting
// at p=0.17. A verdict column would launder that coin flip into an instruction.
//
// The screen therefore ranks by STRUCTURE QUALITY — how legible a chart is —
// and shows the legs side by side so the reader decides direction. The dealer
// posture column is the closest thing to a directional hint, and it says only
// whether the structure is likely to hold or break, not which way.
//
// NULL IS RENDERED AS A DASH, NEVER AS A DEFAULT. Every analytic is tri-state
// (value / null / false) and the dash is load-bearing: a null sma50Above200
// means "under 200 bars, cannot tell", and drawing that as a bearish cross
// would mislabel every young listing on the board.
// =============================================================================
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme.dart';
import '../../../core/widgets/app_menu_button.dart';
import '../models/swing_setup.dart';
import '../providers/swing_setups_provider.dart';
import '../widgets/swing_detail_sheet.dart';

class SwingScreen extends ConsumerWidget {
  const SwingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(swingSetupsProvider);
    final filters = ref.watch(swingFiltersProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Swing Setups'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded, color: Colors.white70),
            tooltip: 'Refresh',
            onPressed: () => ref.invalidate(swingSetupsProvider),
          ),
          const AppMenuButton(),
        ],
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => _Message(
          icon: Icons.error_outline_rounded,
          title: 'Could not load setups',
          detail: '$e',
        ),
        data: (all) {
          if (all.isEmpty) {
            return const _Message(
              icon: Icons.hourglass_empty_rounded,
              title: 'No setups yet',
              detail: 'swing-setups-pull has not written a session yet.',
            );
          }
          final rows = all.where(filters.matches).toList();
          return Column(
            children: [
              _Header(session: all.first.obsDate, shown: rows.length, total: all.length),
              _FilterBar(filters: filters, ref: ref),
              const Divider(height: 1, color: AppTheme.borderColor),
              Expanded(
                child: rows.isEmpty
                    ? const _Message(
                        icon: Icons.filter_alt_off_rounded,
                        title: 'Nothing matches',
                        // An empty AND-filter result is a real answer, not a
                        // failure — most sessions have no candidate that passes
                        // every leg.
                        detail: 'No ticker passes every active filter this session.',
                      )
                    : ListView.separated(
                        itemCount: rows.length,
                        separatorBuilder: (_, _) =>
                            const Divider(height: 1, color: Color(0x22FFFFFF)),
                        itemBuilder: (_, i) => _SetupRow(setup: rows[i]),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final DateTime session;
  final int shown;
  final int total;
  const _Header({required this.session, required this.shown, required this.total});

  @override
  Widget build(BuildContext context) {
    final d = '${session.year}-${session.month.toString().padLeft(2, '0')}-'
        '${session.day.toString().padLeft(2, '0')}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: [
          Text('Session $d',
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15)),
          const SizedBox(width: 8),
          Text('$shown of $total',
              style: const TextStyle(color: AppTheme.neutralColor, fontSize: 12)),
        ],
      ),
    );
  }
}

class _FilterBar extends StatelessWidget {
  final SwingFilters filters;
  final WidgetRef ref;
  const _FilterBar({required this.filters, required this.ref});

  @override
  Widget build(BuildContext context) {
    void set(SwingFilters f) =>
        ref.read(swingFiltersProvider.notifier).state = f;

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Row(
        children: [
          _chip('Channel', filters.channelsOnly,
              () => set(filters.copyWith(channelsOnly: !filters.channelsOnly))),
          _chip('Vol surge', filters.surgeOnly,
              () => set(filters.copyWith(surgeOnly: !filters.surgeOnly))),
          _chip('Target reachable', filters.reachableOnly,
              () => set(filters.copyWith(reachableOnly: !filters.reachableOnly))),
          _chip('Dealers amplify', filters.breakoutSupportedOnly,
              () => set(filters.copyWith(
                  breakoutSupportedOnly: !filters.breakoutSupportedOnly))),
        ],
      ),
    );
  }

  Widget _chip(String label, bool on, VoidCallback onTap) => Padding(
        padding: const EdgeInsets.only(right: 8),
        child: FilterChip(
          label: Text(label),
          selected: on,
          onSelected: (_) => onTap(),
          backgroundColor: AppTheme.elevatedColor,
          selectedColor: AppTheme.profitColor,
          labelStyle: TextStyle(
            color: on ? Colors.black : Colors.white70,
            fontWeight: on ? FontWeight.w700 : FontWeight.w400,
            fontSize: 12,
          ),
          side: const BorderSide(color: AppTheme.borderColor),
        ),
      );
}

class _SetupRow extends StatelessWidget {
  final SwingSetup setup;
  const _SetupRow({required this.setup});

  @override
  Widget build(BuildContext context) {
    final s = setup;
    return InkWell(
      onTap: () => showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: AppTheme.elevatedColor,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        builder: (_) => SwingDetailSheet(setup: s),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(width: 62, child: _tickerCell(s)),
            SizedBox(width: 44, child: _qualityCell(s)),
            Expanded(child: _channelCell(s)),
            SizedBox(width: 74, child: _volumeCell(s)),
            SizedBox(width: 88, child: _optionsCell(s)),
            const Icon(Icons.chevron_right_rounded,
                size: 18, color: AppTheme.neutralColor),
          ],
        ),
      ),
    );
  }

  Widget _tickerCell(SwingSetup s) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(s.ticker,
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14)),
          Text(s.spot == null ? '—' : s.spot!.toStringAsFixed(2),
              style: const TextStyle(color: AppTheme.neutralColor, fontSize: 11)),
        ],
      );

  Widget _qualityCell(SwingSetup s) {
    // Null quality means "no channel", which must not render as a low score.
    if (s.structureQuality == null) {
      return const Text('—',
          style: TextStyle(color: AppTheme.neutralColor, fontSize: 13));
    }
    final q = s.structureQuality!;
    return Text(q.toStringAsFixed(2),
        style: TextStyle(
          color: q >= 0.8
              ? AppTheme.profitColor
              : q >= 0.6
                  ? Colors.white
                  : AppTheme.neutralColor,
          fontWeight: FontWeight.w700,
          fontSize: 13,
        ));
  }

  Widget _channelCell(SwingSetup s) {
    if (!s.channelFound) {
      return Text(
        _reasonLabel(s.channelReason),
        style: const TextStyle(color: AppTheme.neutralColor, fontSize: 11),
      );
    }
    final pos = s.channelPosition;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Text('${s.channelKind} ',
              style: const TextStyle(color: Colors.white, fontSize: 12)),
          Text(s.channelDirection ?? '',
              style: const TextStyle(
                  color: AppTheme.neutralColor, fontSize: 11)),
        ]),
        const SizedBox(height: 3),
        if (pos != null) _positionBar(pos),
      ],
    );
  }

  /// Where price sits between the boundaries. Clamped for DRAWING only — the
  /// numeric position is deliberately allowed outside 0..1 (a break in
  /// progress) and the label still shows the true value.
  Widget _positionBar(double pos) {
    final clamped = pos.clamp(0.0, 1.0);
    return Row(children: [
      Expanded(
        child: SizedBox(
          height: 4,
          child: LayoutBuilder(builder: (_, c) {
            return Stack(children: [
              Container(
                decoration: BoxDecoration(
                  color: AppTheme.borderColor.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Positioned(
                left: (c.maxWidth - 4) * clamped,
                child: Container(
                  width: 4,
                  height: 4,
                  decoration: const BoxDecoration(
                      color: AppTheme.profitColor, shape: BoxShape.circle),
                ),
              ),
            ]);
          }),
        ),
      ),
      const SizedBox(width: 6),
      Text(pos.toStringAsFixed(2),
          style: const TextStyle(color: AppTheme.neutralColor, fontSize: 10)),
    ]);
  }

  Widget _volumeCell(SwingSetup s) {
    final r = s.volRatio;
    final surge = s.volSurge == true;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(r == null ? '—' : '${r.toStringAsFixed(2)}x',
            style: TextStyle(
              color: surge ? AppTheme.profitColor : Colors.white70,
              fontWeight: surge ? FontWeight.w700 : FontWeight.w400,
              fontSize: 12,
            )),
        Text(s.participation ?? '—',
            style: const TextStyle(color: AppTheme.neutralColor, fontSize: 10)),
      ],
    );
  }

  Widget _optionsCell(SwingSetup s) {
    final amplify = s.breakoutSupported == true;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          s.impliedDaysUp == null
              ? '—'
              : '${s.impliedDaysUp!.toStringAsFixed(0)}d',
          style: TextStyle(
            color: s.reachableUp == true ? AppTheme.profitColor : Colors.white70,
            fontWeight:
                s.reachableUp == true ? FontWeight.w700 : FontWeight.w400,
            fontSize: 12,
          ),
        ),
        Text(s.dealerPosture ?? '—',
            style: TextStyle(
              color: amplify ? AppTheme.lossColor : AppTheme.neutralColor,
              fontSize: 10,
            )),
      ],
    );
  }

  static String _reasonLabel(String? r) {
    switch (r) {
      case 'no_valid_channel_pair':
        return 'no channel — boundaries not parallel';
      case 'no_valid_trendline':
        return 'no channel — no line survives';
      case 'insufficient_pivots':
        return 'no channel — too few swings';
      case 'too_few_bars':
        return 'no channel — not enough history';
      case 'inverted_channel':
        return 'no channel — lines crossed';
      case 'zero_atr':
        return 'no channel — no range';
      default:
        return 'no channel';
    }
  }
}

class _Message extends StatelessWidget {
  final IconData icon;
  final String title;
  final String detail;
  const _Message({required this.icon, required this.title, required this.detail});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 40, color: AppTheme.neutralColor),
              const SizedBox(height: 12),
              Text(title,
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 15)),
              const SizedBox(height: 6),
              Text(detail,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: AppTheme.neutralColor, fontSize: 12)),
            ],
          ),
        ),
      );
}
