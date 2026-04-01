// =============================================================================
// features/macro/macro_score_card.dart
// =============================================================================
// Compact dashboard card showing the macro regime score.
// Tapping opens MacroScoreScreen (full breakdown).
// =============================================================================
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/theme.dart';
import '../../services/macro/macro_score_model.dart';
import '../../services/macro/macro_score_provider.dart';
import 'macro_score_screen.dart';

class MacroScoreCard extends ConsumerWidget {
  const MacroScoreCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(macroScoreProvider);

    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute<void>(builder: (_) => const MacroScoreScreen()),
      ),
      child: Container(
        margin: const EdgeInsets.only(bottom: 24),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF1C2128),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFF30363D)),
        ),
        child: async.when(
          loading: () => const _CardShell(
            child: Center(
              child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2)),
            ),
          ),
          error: (_, _) => const _CardShell(
            child: Text('Unable to load',
                style:
                    TextStyle(color: AppTheme.neutralColor, fontSize: 12)),
          ),
          data: (score) => _CardContent(score: score),
        ),
      ),
    );
  }
}

// ─── Loading / error wrapper ──────────────────────────────────────────────────

class _CardShell extends StatelessWidget {
  final Widget child;
  const _CardShell({required this.child});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _header(),
        const SizedBox(height: 16),
        SizedBox(height: 36, child: child),
      ],
    );
  }

  Widget _header() => const Row(
        children: [
          Icon(Icons.analytics_outlined, size: 16, color: AppTheme.neutralColor),
          SizedBox(width: 6),
          Text('Macro Regime',
              style:
                  TextStyle(color: AppTheme.neutralColor, fontSize: 12)),
        ],
      );
}

// ─── Data content ─────────────────────────────────────────────────────────────

class _CardContent extends StatelessWidget {
  final MacroScore score;
  const _CardContent({required this.score});

  @override
  Widget build(BuildContext context) {
    final regime = score.regime;
    final color = _regimeColor(regime);
    final pct = score.total / 100;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header row
        Row(
          children: [
            Icon(Icons.analytics_outlined,
                size: 16, color: AppTheme.neutralColor),
            const SizedBox(width: 6),
            const Text(
              'Macro Regime',
              style: TextStyle(color: AppTheme.neutralColor, fontSize: 12),
            ),
            const Spacer(),
            const Icon(Icons.open_in_full,
                size: 13, color: AppTheme.neutralColor),
          ],
        ),
        const SizedBox(height: 14),

        // Score + regime badge
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Score circle
            _ScoreCircle(score: score.total, color: color),
            const SizedBox(width: 16),
            // Regime label + bar
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(regime.emoji,
                          style: const TextStyle(fontSize: 16)),
                      const SizedBox(width: 6),
                      Text(
                        regime.label,
                        style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            color: color),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: pct,
                      minHeight: 6,
                      backgroundColor: Colors.white.withValues(alpha: 0.08),
                      valueColor: AlwaysStoppedAnimation(color),
                    ),
                  ),
                  const SizedBox(height: 6),
                  // Top 2 signals inline
                  if (score.components.isNotEmpty)
                    Text(
                      score.components
                          .take(2)
                          .map((c) => c.signal)
                          .join('  ·  '),
                      style: const TextStyle(
                          color: AppTheme.neutralColor,
                          fontSize: 10),
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),

        // Strategy hint
        Text(
          regime.strategies.first,
          style: TextStyle(
              color: color.withValues(alpha: 0.9),
              fontSize: 11,
              fontWeight: FontWeight.w500),
        ),
      ],
    );
  }
}

// ─── Small score circle ───────────────────────────────────────────────────────

class _ScoreCircle extends StatelessWidget {
  final double score;
  final Color color;
  const _ScoreCircle({required this.score, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 62,
      height: 62,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: color, width: 2.5),
        color: color.withValues(alpha: 0.1),
      ),
      child: Center(
        child: Text(
          score.toStringAsFixed(0),
          style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w900,
              color: color),
        ),
      ),
    );
  }
}

// ─── Regime color ─────────────────────────────────────────────────────────────

Color _regimeColor(MacroRegime r) => switch (r) {
      MacroRegime.riskOn         => const Color(0xFF3FB950),
      MacroRegime.neutralBullish => const Color(0xFF58A6FF),
      MacroRegime.neutral        => const Color(0xFFD29922),
      MacroRegime.caution        => const Color(0xFFF0883E),
      MacroRegime.crisis         => const Color(0xFFFF7B72),
    };
