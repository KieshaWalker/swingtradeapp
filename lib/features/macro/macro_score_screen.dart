// =============================================================================
// features/macro/macro_score_screen.dart
// =============================================================================
// Full-screen macro regime breakdown.
// Shows score gauge, each sub-component bar, and strategy recommendations.
// =============================================================================
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/theme.dart';
import '../../services/macro/macro_score_model.dart';
import '../../services/macro/macro_score_provider.dart';
import 'iv_crush_tracker_screen.dart';

class MacroScoreScreen extends ConsumerWidget {
  const MacroScoreScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(macroScoreProvider);

    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      appBar: AppBar(
        backgroundColor: const Color(0xFF161B22),
        title: const Text('Macro Regime Score'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(macroScoreProvider),
          ),
        ],
      ),
      body: async.when(
        loading: () =>
            const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Text('Error: $e',
              style: const TextStyle(color: AppTheme.neutralColor)),
        ),
        data: (score) => _ScoreBody(score: score),
      ),
    );
  }
}

// ─── Body ─────────────────────────────────────────────────────────────────────

class _ScoreBody extends StatelessWidget {
  final MacroScore score;
  const _ScoreBody({required this.score});

  @override
  Widget build(BuildContext context) {
    final regime = score.regime;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 40),
      children: [
        // Gauge + regime badge
        _GaugeTile(score: score),
        const SizedBox(height: 24),

        // Components
        const Text(
          'Score Components',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 12),
        ...score.components.map((c) => _ComponentRow(c: c)),
        const SizedBox(height: 28),

        // Strategy recommendations
        _StrategySection(regime: regime),
        const SizedBox(height: 28),

        // Regime description
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFF1C2128),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFF30363D)),
          ),
          child: Text(
            regime.description,
            style: const TextStyle(
                color: AppTheme.neutralColor,
                fontSize: 13,
                height: 1.5),
          ),
        ),
        const SizedBox(height: 12),

        // IV Crush Tracker link
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute<void>(
                builder: (_) => const IvCrushTrackerScreen()),
          ),
          icon: const Icon(Icons.compress_outlined, size: 16),
          label: const Text('IV Crush Tracker'),
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.white70,
            side: const BorderSide(color: Color(0xFF30363D)),
            minimumSize: const Size(double.infinity, 44),
          ),
        ),
        const SizedBox(height: 16),

        // Methodology note
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            score.usedZScores
                ? 'Score uses Z-score normalization vs rolling history'
                : 'Building history — score uses threshold fallbacks',
            style: const TextStyle(color: AppTheme.neutralColor, fontSize: 11),
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 4),

        if (!score.hasEnoughData)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              'Some components used fallback data. Scores will improve as more historical data accumulates.',
              style: TextStyle(color: AppTheme.neutralColor, fontSize: 11),
              textAlign: TextAlign.center,
            ),
          ),

        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            'Updated ${_fmt(score.computedAt)}',
            style: const TextStyle(color: AppTheme.neutralColor, fontSize: 11),
            textAlign: TextAlign.center,
          ),
        ),
      ],
    );
  }

  String _fmt(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '${dt.month}/${dt.day}/${dt.year} $h:$m';
  }
}

// ─── Score Gauge ──────────────────────────────────────────────────────────────

class _GaugeTile extends StatelessWidget {
  final MacroScore score;
  const _GaugeTile({required this.score});

  @override
  Widget build(BuildContext context) {
    final regime = score.regime;
    final color = _regimeColor(regime);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      decoration: BoxDecoration(
        color: const Color(0xFF1C2128),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF30363D)),
      ),
      child: Column(
        children: [
          SizedBox(
            width: 160,
            height: 160,
            child: CustomPaint(
              painter: _ArcPainter(
                value: score.total / 100,
                color: color,
              ),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      score.total.toStringAsFixed(0),
                      style: TextStyle(
                          fontSize: 42,
                          fontWeight: FontWeight.w900,
                          color: color),
                    ),
                    const Text(
                      '/ 100',
                      style: TextStyle(
                          color: AppTheme.neutralColor, fontSize: 13),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(30),
              border: Border.all(color: color.withValues(alpha: 0.4)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(regime.emoji,
                    style: const TextStyle(fontSize: 18)),
                const SizedBox(width: 8),
                Text(
                  regime.label,
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: color),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Arc painter ──────────────────────────────────────────────────────────────

class _ArcPainter extends CustomPainter {
  final double value; // 0.0 – 1.0
  final Color color;
  const _ArcPainter({required this.value, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 10;
    const start = math.pi * 0.75;   // bottom-left
    const sweep = math.pi * 1.5;    // 270° arc

    final trackPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 12
      ..strokeCap = StrokeCap.round
      ..color = Colors.white.withValues(alpha: 0.08);

    final fillPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 12
      ..strokeCap = StrokeCap.round
      ..color = color;

    canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        start, sweep, false, trackPaint);
    canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        start, sweep * value, false, fillPaint);
  }

  @override
  bool shouldRepaint(_ArcPainter old) =>
      old.value != value || old.color != color;
}

// ─── Component row ────────────────────────────────────────────────────────────

class _ComponentRow extends StatelessWidget {
  final MacroSubScore c;
  const _ComponentRow({required this.c});

  @override
  Widget build(BuildContext context) {
    final barColor = c.isPositive ? AppTheme.profitColor : AppTheme.lossColor;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1C2128),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF30363D)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                c.isPositive ? Icons.check_circle_outline : Icons.cancel_outlined,
                size: 14,
                color: barColor,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  c.name,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
              Text(
                '${c.score.toStringAsFixed(0)} / ${c.maxScore.toStringAsFixed(0)}',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: barColor),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: c.pct,
              minHeight: 5,
              backgroundColor: Colors.white.withValues(alpha: 0.06),
              valueColor: AlwaysStoppedAnimation(barColor),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            c.signal,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 2),
          Text(
            c.detail,
            style: const TextStyle(
                color: AppTheme.neutralColor, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

// ─── Strategy section ─────────────────────────────────────────────────────────

class _StrategySection extends StatelessWidget {
  final MacroRegime regime;
  const _StrategySection({required this.regime});

  @override
  Widget build(BuildContext context) {
    final color = _regimeColor(regime);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Recommended Strategies',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 10),
        ...regime.strategies.map(
          (s) => Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.arrow_right, size: 18, color: color),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(s,
                      style: const TextStyle(fontSize: 13, height: 1.4)),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

Color _regimeColor(MacroRegime r) => switch (r) {
      MacroRegime.riskOn         => const Color(0xFF3FB950),  // green
      MacroRegime.neutralBullish => const Color(0xFF58A6FF),  // blue
      MacroRegime.neutral        => const Color(0xFFD29922),  // yellow
      MacroRegime.caution        => const Color(0xFFF0883E),  // orange
      MacroRegime.crisis         => const Color(0xFFFF7B72),  // red
    };
