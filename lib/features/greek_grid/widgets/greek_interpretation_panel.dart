// =============================================================================
// features/greek_grid/widgets/greek_interpretation_panel.dart
// =============================================================================
// Collapsible interpretation card shared by GreekGridScreen and
// GreekChartScreen.
//
// Collapsed: headline + signal dot + chevron.
// Expanded:  TODAY section (per-metric) + PERIOD section (trend).
// =============================================================================

import 'package:flutter/material.dart';
import '../../../../core/theme.dart';
import '../services/greek_interpreter.dart';

class GreekInterpretationPanel extends StatefulWidget {
  final InterpretationResult result;
  const GreekInterpretationPanel({super.key, required this.result});

  @override
  State<GreekInterpretationPanel> createState() =>
      _GreekInterpretationPanelState();
}

class _GreekInterpretationPanelState extends State<GreekInterpretationPanel> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final r          = widget.result;
    final borderCol  = _signalColor(r.headlineSignal).withValues(alpha: 0.35);

    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      curve:    Curves.easeInOut,
      child: Container(
        decoration: BoxDecoration(
          color:        AppTheme.cardColor,
          borderRadius: BorderRadius.circular(10),
          border:       Border.all(color: borderCol),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Collapsed header (always visible) ──────────────────────────
            InkWell(
              onTap:        () => setState(() => _expanded = !_expanded),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(10)),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                child: Row(
                  children: [
                    // Signal dot
                    Container(
                      width:  7,
                      height: 7,
                      margin: const EdgeInsets.only(right: 8),
                      decoration: BoxDecoration(
                        color:  _signalColor(r.headlineSignal),
                        shape:  BoxShape.circle,
                      ),
                    ),
                    // Label
                    const Text(
                      'INTERPRETATION',
                      style: TextStyle(
                        color:       AppTheme.neutralColor,
                        fontSize:    9,
                        fontWeight:  FontWeight.w700,
                        letterSpacing: 1.0,
                      ),
                    ),
                    const SizedBox(width: 8),
                    // Headline
                    Expanded(
                      child: Text(
                        r.headline,
                        style: const TextStyle(
                          color:      Colors.white,
                          fontSize:   11,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines:  2,
                        overflow:  TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Icon(
                      _expanded
                          ? Icons.keyboard_arrow_up_rounded
                          : Icons.keyboard_arrow_down_rounded,
                      color: AppTheme.neutralColor,
                      size:  16,
                    ),
                  ],
                ),
              ),
            ),

            // ── Expanded body ───────────────────────────────────────────────
            if (_expanded) ...[
              Divider(height: 1, color: AppTheme.borderColor.withValues(alpha: 0.4)),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (r.today.isNotEmpty) ...[
                      const _SectionLabel('TODAY'),
                      const SizedBox(height: 6),
                      for (final line in r.today) _InterpLine(line: line),
                    ],
                    if (r.today.isNotEmpty && r.period.isNotEmpty)
                      const SizedBox(height: 10),
                    if (r.period.isNotEmpty) ...[
                      _SectionLabel(
                        'PERIOD  ·  ${r.periodObs} observation${r.periodObs == 1 ? "" : "s"}',
                      ),
                      const SizedBox(height: 6),
                      for (final line in r.period) _InterpLine(line: line),
                    ],
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Color _signalColor(InterpretationSignal s) => switch (s) {
    InterpretationSignal.bullish  => AppTheme.profitColor,
    InterpretationSignal.bearish  => AppTheme.lossColor,
    InterpretationSignal.caution  => const Color(0xFFFFAB40),
    InterpretationSignal.neutral  => AppTheme.neutralColor,
  };
}

// ── Section label ─────────────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: const TextStyle(
      color:        AppTheme.neutralColor,
      fontSize:     9,
      fontWeight:   FontWeight.w700,
      letterSpacing: 1.0,
    ),
  );
}

// ── Single interpretation line ────────────────────────────────────────────────

class _InterpLine extends StatelessWidget {
  final InterpretationLine line;
  const _InterpLine({required this.line});

  static Color _dot(InterpretationSignal s) => switch (s) {
    InterpretationSignal.bullish  => AppTheme.profitColor,
    InterpretationSignal.bearish  => AppTheme.lossColor,
    InterpretationSignal.caution  => const Color(0xFFFFAB40),
    InterpretationSignal.neutral  => AppTheme.neutralColor,
  };

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 7),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 5, right: 7),
          child: Container(
            width:  5,
            height: 5,
            decoration: BoxDecoration(
              color:  _dot(line.signal),
              shape:  BoxShape.circle,
            ),
          ),
        ),
        Expanded(
          child: RichText(
            text: TextSpan(
              children: [
                TextSpan(
                  text: '${line.label}  ',
                  style: const TextStyle(
                    color:      Colors.white70,
                    fontSize:   11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                TextSpan(
                  text: line.text,
                  style: const TextStyle(
                    color:  Colors.white54,
                    fontSize: 11,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}
