// =============================================================================
// features/blotter/screens/trade_blotter_action_widgets.dart
// =============================================================================
// Blotter log + sticky action bar widgets:
//   RecentBlotterCard, LogHdr, BlotterLogRow, ActionBar, ActionButton
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme.dart';
import '../models/blotter_models.dart';
import 'trade_blotter_form_widgets.dart' show SectionCard;

// ── Recent trades provider ────────────────────────────────────────────────────

final recentBlotterProvider = FutureProvider.autoDispose<List<BlotterTrade>>((
  ref,
) async {
  final rows = await Supabase.instance.client
      .from('blotter_trades')
      .select()
      .order('created_at', ascending: false)
      .limit(10);
  return rows.map((r) => BlotterTrade.fromJson(r)).toList();
});

// ── Recent blotter trades ─────────────────────────────────────────────────────

class RecentBlotterCard extends StatelessWidget {
  final WidgetRef ref;
  const RecentBlotterCard({super.key, required this.ref});

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(recentBlotterProvider);
    return SectionCard(
      label: 'BLOTTER LOG',
      accent: const Color(0xFF94A3B8),
      child: async.when(
        loading: () => const Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
        error: (_, _) => const Text(
          'Failed to load',
          style: TextStyle(color: AppTheme.lossColor),
        ),
        data: (trades) {
          if (trades.isEmpty) {
            return const Text(
              'No staged trades yet. Validate and commit a trade to see it here.',
              style: TextStyle(color: Color(0xFF6B7280), fontSize: 12),
            );
          }
          return Column(
            children: [
              // Header
              const Padding(
                padding: EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    Expanded(flex: 3, child: LogHdr('INSTRUMENT')),
                    Expanded(flex: 2, child: LogHdr('STRATEGY')),
                    Expanded(flex: 2, child: LogHdr('EDGE')),
                    Expanded(flex: 2, child: LogHdr('STATUS')),
                  ],
                ),
              ),
              ...trades.map((t) => BlotterLogRow(trade: t)),
            ],
          );
        },
      ),
    );
  }
}

class LogHdr extends StatelessWidget {
  final String text;
  const LogHdr(this.text, {super.key});
  @override
  Widget build(BuildContext context) => Text(
    text,
    style: const TextStyle(
      color: Color(0xFF6B7280),
      fontSize: 9,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.8,
    ),
  );
}

class BlotterLogRow extends StatelessWidget {
  final BlotterTrade trade;
  const BlotterLogRow({super.key, required this.trade});

  @override
  Widget build(BuildContext context) {
    final typeColor = trade.contractType == ContractType.call
        ? AppTheme.profitColor
        : AppTheme.lossColor;
    final edge = trade.fairValueResult?.edgeBps;
    final edgeStr = edge == null
        ? '—'
        : '${edge >= 0 ? '+' : ''}${edge.toStringAsFixed(1)}';
    final edgeColor = edge == null
        ? const Color(0xFF6B7280)
        : edge > 0
        ? AppTheme.profitColor
        : AppTheme.lossColor;

    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF0F0F14),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${trade.symbol} \$${trade.strike.toStringAsFixed(0)} '
                  '${trade.contractType.label}',
                  style: TextStyle(
                    color: typeColor,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  trade.expiration,
                  style: const TextStyle(color: Color(0xFF6B7280), fontSize: 9),
                ),
              ],
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              trade.strategyTag.label,
              style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 9),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              '$edgeStr bps',
              style: TextStyle(
                color: edgeColor,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                fontFamily: 'monospace',
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: trade.status.color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: trade.status.color.withValues(alpha: 0.35),
                ),
              ),
              child: Text(
                trade.status.label,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: trade.status.color,
                  fontSize: 8,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Sticky action bar ─────────────────────────────────────────────────────────

class ActionBar extends StatelessWidget {
  final TradeStatus status;
  final bool isValidating, isCommitting, isTransmitting;
  final WhatIfResult? whatIf;
  final VoidCallback onValidate, onCommit, onTransmit;

  const ActionBar({
    super.key,
    required this.status,
    required this.isValidating,
    required this.isCommitting,
    required this.isTransmitting,
    required this.whatIf,
    required this.onValidate,
    required this.onCommit,
    required this.onTransmit,
  });

  @override
  Widget build(BuildContext context) {
    final blocked = whatIf?.exceedsDeltaThreshold ?? false;

    return Container(
      padding: EdgeInsets.fromLTRB(
        14,
        12,
        14,
        12 + MediaQuery.paddingOf(context).bottom,
      ),
      decoration: const BoxDecoration(
        color: Color(0xFF0F0F14),
        border: Border(top: BorderSide(color: Color(0xFF2A2A38))),
      ),
      child: Row(
        children: [
          // Validate
          Expanded(
            child: ActionButton(
              label: 'VALIDATE',
              icon: Icons.fact_check_outlined,
              color: const Color(0xFF60A5FA),
              loading: isValidating,
              enabled:
                  status == TradeStatus.draft ||
                  status == TradeStatus.validated,
              onTap: onValidate,
            ),
          ),

          const SizedBox(width: 8),

          // Commit to DB
          Expanded(
            child: Tooltip(
              message: blocked
                  ? 'Delta limit exceeded — reduce size or add hedge'
                  : status != TradeStatus.validated
                  ? 'Validate the trade first'
                  : '',
              child: ActionButton(
                label: 'COMMIT DB',
                icon: Icons.storage_outlined,
                color: const Color(0xFFFBBF24),
                loading: isCommitting,
                enabled: status == TradeStatus.validated && !blocked,
                onTap: onCommit,
              ),
            ),
          ),

          const SizedBox(width: 8),

          // Transmit
          Expanded(
            child: Tooltip(
              message: status != TradeStatus.committed
                  ? 'Write to DB first before transmitting'
                  : '',
              child: ActionButton(
                label: 'TRANSMIT',
                icon: Icons.send_rounded,
                color: AppTheme.profitColor,
                loading: isTransmitting,
                enabled: status == TradeStatus.committed,
                onTap: onTransmit,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class ActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final bool loading, enabled;
  final VoidCallback onTap;

  const ActionButton({
    super.key,
    required this.label,
    required this.icon,
    required this.color,
    required this.loading,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveColor = enabled ? color : const Color(0xFF2A2A38);
    return GestureDetector(
      onTap: enabled && !loading ? onTap : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(vertical: 13),
        decoration: BoxDecoration(
          color: enabled
              ? color.withValues(alpha: 0.12)
              : const Color(0xFF0F0F14),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: effectiveColor.withValues(alpha: enabled ? 0.5 : 0.2),
          ),
        ),
        child: loading
            ? Center(
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: color,
                  ),
                ),
              )
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, color: effectiveColor, size: 14),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: TextStyle(
                      color: effectiveColor,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.8,
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
