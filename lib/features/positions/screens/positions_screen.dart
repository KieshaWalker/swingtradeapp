// =============================================================================
// features/positions/screens/positions_screen.dart — Greek exposure table
// =============================================================================
// Each position the user enters (with option + underlying legs) is displayed
// as a card showing per-leg aggregated Greeks, theoretical edge, and an
// auto-generated interpretation of what the position wants the market to do.
// A summary card at the bottom aggregates across all positions.
// =============================================================================
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme.dart';
import '../../../core/widgets/app_menu_button.dart';
import '../models/position_models.dart';
import '../providers/positions_provider.dart';
import '../widgets/add_position_dialog.dart';

class PositionsScreen extends ConsumerWidget {
  const PositionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enrichedAsync = ref.watch(enrichedPositionsProvider);
    final notifier = ref.read(positionsProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Positions Table'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded, color: Colors.white70),
            tooltip: 'Refresh live data',
            onPressed: () => ref.invalidate(enrichedPositionsProvider),
          ),
          const AppMenuButton(),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: AppTheme.profitColor,
        foregroundColor: Colors.black,
        icon: const Icon(Icons.add),
        label: const Text('Add Position',
            style: TextStyle(fontWeight: FontWeight.w700)),
        onPressed: () => showAddPositionDialog(
          context,
          onSave: notifier.add,
        ),
      ),
      body: enrichedAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => _ErrorView(message: e.toString()),
        data: (positions) {
          if (positions.isEmpty) return const _EmptyState();
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
            children: [
              for (int i = 0; i < positions.length; i++)
                _PositionCard(
                  ep: positions[i],
                  index: i,
                  onEdit: () => showAddPositionDialog(
                    context,
                    existing: positions[i].position,
                    onSave: notifier.update,
                  ),
                  onDelete: () => _confirmDelete(
                    context,
                    positions[i].position.name,
                    () => notifier.remove(positions[i].position.id),
                  ),
                ),
              const SizedBox(height: 8),
              _SummaryCard(positions: positions),
            ],
          );
        },
      ),
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    String name,
    VoidCallback onConfirm,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.elevatedColor,
        title: const Text('Delete position?',
            style: TextStyle(color: Colors.white)),
        content: Text('Remove "$name"?',
            style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete',
                style: TextStyle(color: AppTheme.lossColor)),
          ),
        ],
      ),
    );
    if (ok == true) onConfirm();
  }
}

// ── Position card ─────────────────────────────────────────────────────────────

class _PositionCard extends StatelessWidget {
  final EnrichedPosition ep;
  final int index;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _PositionCard({
    required this.ep,
    required this.index,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: AppTheme.cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 8, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _positionBadge('P${index + 1}'),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        ep.position.name,
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 14),
                      ),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: ep.position.legs
                            .map((l) => _legChip(l.label))
                            .toList(),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.edit_outlined,
                      size: 17, color: AppTheme.neutralColor),
                  onPressed: onEdit,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline,
                      size: 17, color: AppTheme.lossColor),
                  onPressed: onDelete,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: AppTheme.borderColor),
          // Edge by model
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Edge vs model',
                    style: TextStyle(
                        color: AppTheme.neutralColor,
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.4)),
                const SizedBox(height: 6),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _GreekCell(label: 'B-S', value: ep.totalEdgeVsBs),
                      const SizedBox(width: 5),
                      _GreekCell(label: 'SABR', value: ep.totalEdgeVsSabr),
                      const SizedBox(width: 5),
                      _GreekCell(
                          label: 'Heston', value: ep.totalEdgeVsHeston),
                      const SizedBox(width: 5),
                      _GreekCell(label: 'Best', value: ep.totalEdgeVsModel),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: AppTheme.borderColor),
          // Greeks row
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _GreekCell(label: 'Δ Delta', value: ep.totalDelta),
                  const SizedBox(width: 5),
                  _GreekCell(label: 'Γ Gamma', value: ep.totalGamma),
                  const SizedBox(width: 5),
                  _GreekCell(label: 'Θ Theta', value: ep.totalTheta),
                  const SizedBox(width: 5),
                  _GreekCell(label: 'V Vega', value: ep.totalVega),
                  const SizedBox(width: 5),
                  _GreekCell(label: 'ρ Rho', value: ep.totalRho),
                ],
              ),
            ),
          ),
          // Interpretation
          if (ep.hasLiveData) ...[
            const Divider(height: 1, color: AppTheme.borderColor),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
              child: Text(
                ep.interpretation,
                style: const TextStyle(
                  color: AppTheme.neutralColor,
                  fontSize: 11,
                  fontStyle: FontStyle.italic,
                  height: 1.5,
                ),
              ),
            ),
          ] else ...[
            const Divider(height: 1, color: AppTheme.borderColor),
            const Padding(
              padding: EdgeInsets.fromLTRB(14, 8, 14, 10),
              child: Text(
                'Live Greeks unavailable — check Schwab connection',
                style: TextStyle(
                    color: Colors.white38,
                    fontSize: 11,
                    fontStyle: FontStyle.italic),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _positionBadge(String label) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: AppTheme.profitColor.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
              color: AppTheme.profitColor.withValues(alpha: 0.4)),
        ),
        child: Text(
          label,
          style: const TextStyle(
              color: AppTheme.profitColor,
              fontSize: 11,
              fontWeight: FontWeight.w700),
        ),
      );

  Widget _legChip(String label) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: AppTheme.elevatedColor,
          borderRadius: BorderRadius.circular(5),
        ),
        child: Text(label,
            style: const TextStyle(color: Colors.white60, fontSize: 11)),
      );
}

// ── Summary card ──────────────────────────────────────────────────────────────

class _SummaryCard extends StatelessWidget {
  final List<EnrichedPosition> positions;

  const _SummaryCard({required this.positions});

  @override
  Widget build(BuildContext context) {
    final totalEdge = positions.fold(0.0, (s, p) => s + p.totalEdge);
    final totalDelta = positions.fold(0.0, (s, p) => s + p.totalDelta);
    final totalGamma = positions.fold(0.0, (s, p) => s + p.totalGamma);
    final totalTheta = positions.fold(0.0, (s, p) => s + p.totalTheta);
    final totalVega = positions.fold(0.0, (s, p) => s + p.totalVega);
    final totalRho = positions.fold(0.0, (s, p) => s + p.totalRho);

    return Container(
      decoration: BoxDecoration(
        color: AppTheme.elevatedColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.profitColor.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
            child: Row(
              children: [
                const Icon(Icons.functions_rounded,
                    size: 15, color: AppTheme.profitColor),
                const SizedBox(width: 6),
                const Text(
                  'Book Summary',
                  style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 14),
                ),
                const SizedBox(width: 8),
                Text(
                  '${positions.length} position${positions.length == 1 ? '' : 's'}',
                  style: const TextStyle(
                      color: AppTheme.neutralColor, fontSize: 11),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: AppTheme.borderColor),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _GreekCell(label: 'Σ Edge', value: totalEdge),
                  const SizedBox(width: 5),
                  _GreekCell(label: 'Σ Δ', value: totalDelta),
                  const SizedBox(width: 5),
                  _GreekCell(label: 'Σ Γ', value: totalGamma),
                  const SizedBox(width: 5),
                  _GreekCell(label: 'Σ Θ', value: totalTheta),
                  const SizedBox(width: 5),
                  _GreekCell(label: 'Σ V', value: totalVega),
                  const SizedBox(width: 5),
                  _GreekCell(label: 'Σ ρ', value: totalRho),
                ],
              ),
            ),
          ),
          const Divider(height: 1, color: AppTheme.borderColor),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
            child: Text(
              EnrichedPosition.buildInterpretation(
                  totalDelta, totalGamma, totalTheta, totalVega, totalRho),
              style: const TextStyle(
                color: AppTheme.neutralColor,
                fontSize: 11,
                fontStyle: FontStyle.italic,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Greek cell ────────────────────────────────────────────────────────────────

class _GreekCell extends StatelessWidget {
  final String label;
  final double? value; // null → not available (e.g. Heston not calibrated)

  const _GreekCell({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final v = value;
    final isNull = v == null;
    final isZero = !isNull && v.abs() < 0.001;
    final color = (isNull || isZero)
        ? AppTheme.neutralColor
        : (v > 0 ? AppTheme.profitColor : AppTheme.lossColor);
    final displayText = isNull
        ? 'N/A'
        : (isZero ? '—' : '${v >= 0 ? '+' : ''}${v.toStringAsFixed(2)}');

    return Container(
      width: 76,
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      decoration: BoxDecoration(
        color: AppTheme.cardColor,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: const TextStyle(
                color: AppTheme.neutralColor,
                fontSize: 10,
                fontWeight: FontWeight.w500),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 5),
          Text(
            displayText,
            style: TextStyle(
                color: color, fontSize: 13, fontWeight: FontWeight.w700),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

// ── Empty / error states ──────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.layers_outlined,
              size: 52, color: AppTheme.neutralColor.withValues(alpha: 0.5)),
          const SizedBox(height: 16),
          const Text('No positions yet',
              style: TextStyle(
                  color: Colors.white70,
                  fontSize: 16,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          const Text('Tap + Add Position to enter your first trade',
              style: TextStyle(color: AppTheme.neutralColor, fontSize: 13)),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  const _ErrorView({required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: AppTheme.lossColor, size: 40),
            const SizedBox(height: 12),
            const Text('Could not load live data',
                style: TextStyle(color: Colors.white70, fontSize: 15)),
            const SizedBox(height: 6),
            Text(message,
                style: const TextStyle(
                    color: AppTheme.neutralColor, fontSize: 11),
                textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
