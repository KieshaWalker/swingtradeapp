// features/economy/screens/crisis_history_screen.dart — the evidence base
//
// The full 13-crisis historical record (data/crisis_history.dart) rendered as
// expandable case files. Each crisis lists the signals that preceded it; chips
// light up when that same signal is firing on today's live checklist, so the
// comparison "which of 1929's warnings are present now" is a glance, not a
// research project.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../history/crisis_history.dart';
import '../widgets/crisis_ledger_tab.dart' show crisisChecklistProvider;

class CrisisHistoryScreen extends ConsumerWidget {
  const CrisisHistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(crisisChecklistProvider);
    // Signals firing on the latest live snapshot ('v_index_ath' -> 'index_ath')
    final firingToday = async.valueOrNull?.isNotEmpty == true
        ? async.value!.first.verdicts.entries
            .where((e) => e.value == 'firing')
            .map((e) => e.key.replaceFirst('v_', ''))
            .toSet()
        : const <String>{};

    return Scaffold(
      appBar: AppBar(title: const Text('Crisis History — The Evidence')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          Text(
            'Thirteen U.S. market crises, 1873–2022. Every case file records '
            'the lead-up, the trigger, what was visible beforehand, the macro '
            'backdrop, and how long recovery took. Signal chips light red when '
            'that same warning is firing on today\'s checklist.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          for (final c in crisisHistory)
            _CrisisCard(record: c, firingToday: firingToday),
        ],
      ),
    );
  }
}

class _CrisisCard extends StatefulWidget {
  final CrisisRecord record;
  final Set<String> firingToday;
  const _CrisisCard({required this.record, required this.firingToday});

  @override
  State<_CrisisCard> createState() => _CrisisCardState();
}

class _CrisisCardState extends State<_CrisisCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = widget.record;
    final overlap =
        c.signalsPresent.where(widget.firingToday.contains).length;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: () => setState(() => _expanded = !_expanded),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(c.name,
                          style: theme.textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w700)),
                      Text('${c.years} · ${c.index}',
                          style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurface
                                  .withValues(alpha: 0.55))),
                    ]),
              ),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(c.drawdown,
                    style: theme.textTheme.titleSmall?.copyWith(
                        color: theme.colorScheme.error,
                        fontWeight: FontWeight.w700)),
                Text('reclaimed in ${c.recovery.split(' — ').first}',
                    style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurface
                            .withValues(alpha: 0.55))),
              ]),
            ]),
            const SizedBox(height: 10),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final key in c.signalsPresent)
                _SignalChip(
                  label: crisisSignalLabels[key] ?? key,
                  firingNow: widget.firingToday.contains(key),
                ),
            ]),
            if (overlap > 0)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '$overlap of ${c.signalsPresent.length} of this crisis\'s '
                  'warnings are firing today',
                  style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.error,
                      fontWeight: FontWeight.w600),
                ),
              ),
            if (_expanded) ...[
              const SizedBox(height: 12),
              _Section('Peak → trough', '${c.peak}  →  ${c.trough}'),
              _Section('Decline length', c.declineLength),
              _Section('The lead-up', c.leadUp),
              _Section('The trigger', c.trigger),
              _Section('Underlying causes', c.causes),
              _Section('Visible beforehand', c.warnings),
              _Section('Inflation', c.inflation),
              _Section('Bonds & rates', c.bonds),
              _Section('Recession', c.recession),
              _Section('Time to reclaim peak', c.recovery),
              _Section('Preceding bull', c.precedingBull),
              _Section('Structural aftermath', c.aftermath),
            ] else
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('Tap for the full case file',
                    style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurface
                            .withValues(alpha: 0.4))),
              ),
          ]),
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title, body;
  const _Section(this.title, this.body);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title.toUpperCase(),
            style: theme.textTheme.labelSmall?.copyWith(
                letterSpacing: 1.0,
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.primary)),
        const SizedBox(height: 2),
        Text(body, style: theme.textTheme.bodySmall),
      ]),
    );
  }
}

class _SignalChip extends StatelessWidget {
  final String label;
  final bool firingNow;
  const _SignalChip({required this.label, required this.firingNow});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = firingNow
        ? theme.colorScheme.error
        : theme.colorScheme.onSurface.withValues(alpha: 0.45);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(999),
        color: firingNow
            ? theme.colorScheme.error.withValues(alpha: 0.08)
            : null,
      ),
      child: Text(label,
          style: theme.textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: firingNow ? FontWeight.w700 : FontWeight.w500)),
    );
  }
}
