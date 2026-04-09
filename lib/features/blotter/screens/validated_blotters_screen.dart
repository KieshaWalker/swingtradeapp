// =============================================================================
// features/blotter/screens/validated_blotters_screen.dart
// =============================================================================
// View of current committed blotters — trades that have been committed or transmitted.
//
// Displays a list of blotter trades with status 'committed' or 'sent'.
// Allows review of persisted blotter history.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme.dart';
import '../../../core/widgets/app_menu_button.dart';
import '../models/blotter_models.dart';

// ── Validated blotters provider ──────────────────────────────────────────────

final committedBlottersProvider = FutureProvider<List<BlotterTrade>>((
  ref,
) async {
  final rows = await Supabase.instance.client
      .from('blotter_trades')
      .select()
      .inFilter('status', ['committed', 'sent'])
      .order('created_at', ascending: false);
  return rows.map((r) => BlotterTrade.fromJson(r)).toList();
});

// ── Screen ───────────────────────────────────────────────────────────────────

class ValidatedBlottersScreen extends ConsumerWidget {
  const ValidatedBlottersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncBlotters = ref.watch(committedBlottersProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Committed Blotters'),
        actions: const [AppMenuButton()],
      ),
      body: asyncBlotters.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, _) => Center(
          child: Text(
            'Error loading validated blotters: $err',
            style: const TextStyle(color: AppTheme.lossColor),
          ),
        ),
        data: (blotters) {
          if (blotters.isEmpty) {
            return const Center(
              child: Text(
                'No committed blotters yet.',
                style: TextStyle(color: AppTheme.neutralColor),
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: blotters.length,
            itemBuilder: (context, index) {
              final trade = blotters[index];
              return CommittedBlotterCard(trade: trade);
            },
          );
        },
      ),
    );
  }
}

// ── Blotter card widget ───────────────────────────────────────────────────────

class CommittedBlotterCard extends StatelessWidget {
  final BlotterTrade trade;
  const CommittedBlotterCard({super.key, required this.trade});

  @override
  Widget build(BuildContext context) {
    final typeColor = trade.contractType == ContractType.call
        ? AppTheme.profitColor
        : AppTheme.lossColor;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header: Symbol, Type, Strike, Expiration
            Row(
              children: [
                Text(
                  '${trade.symbol} \$${trade.strike.toStringAsFixed(0)} ${trade.contractType.label}',
                  style: TextStyle(
                    color: typeColor,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: trade.status.color.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: trade.status.color.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Text(
                    trade.status.label,
                    style: TextStyle(
                      color: trade.status.color,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Expiration: ${trade.expiration}',
              style: const TextStyle(
                color: AppTheme.neutralColor,
                fontSize: 14,
              ),
            ),
            Text(
              'Quantity: ${trade.quantity} (${trade.strategyTag.label})',
              style: const TextStyle(
                color: AppTheme.neutralColor,
                fontSize: 14,
              ),
            ),
            if (trade.notes != null) ...[
              const SizedBox(height: 8),
              Text(
                'Notes: ${trade.notes}',
                style: const TextStyle(
                  color: AppTheme.neutralColor,
                  fontSize: 12,
                ),
              ),
            ],
            // Fair value if available
            if (trade.fairValueResult != null) ...[
              const SizedBox(height: 12),
              Divider(color: AppTheme.borderColor),
              const SizedBox(height: 8),
              Text(
                'Fair Value: \$${trade.fairValueResult!.modelFairValue.toStringAsFixed(3)} (${trade.fairValueResult!.edgeBps >= 0 ? '+' : ''}${trade.fairValueResult!.edgeBps.toStringAsFixed(1)} bps)',
                style: TextStyle(
                  color: trade.fairValueResult!.edgeColor,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            // Greeks if available
            if (trade.delta != null) ...[
              const SizedBox(height: 8),
              Text(
                'Greeks: Δ ${trade.delta!.toStringAsFixed(3)}, Γ ${trade.gamma?.toStringAsFixed(5) ?? '—'}, Θ ${trade.theta?.toStringAsFixed(3) ?? '—'}, ν ${trade.vega?.toStringAsFixed(3) ?? '—'}',
                style: const TextStyle(
                  color: AppTheme.neutralColor,
                  fontSize: 12,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
