// =============================================================================
// features/blotter/widgets/phase_stepper.dart
// =============================================================================
// Horizontal 5-step progress indicator for the trade evaluation workflow.
//
// Each step shows:
//   • Numbered circle — colored by PhaseStatus (slate/green/amber/rose)
//   • Status icon overlay once evaluated (check / warning / cancel)
//   • Label below the circle
//   • Connecting line between adjacent steps
//
// Usage:
//   PhaseStepper(results: [p1, p2, p3, p4, p5])
// =============================================================================

import 'package:flutter/material.dart';
import '../../../core/theme.dart';
import '../models/phase_result.dart';

const _labels = ['Economic', 'Formula', 'Blotter', 'Vol Surface', 'Greek Grid', 'Kalshi'];

class PhaseStepper extends StatelessWidget {
  final List<PhaseResult> results; // must be exactly 6 elements

  const PhaseStepper({super.key, required this.results})
      : assert(results.length == 6);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: List.generate(6, (i) {
          final isLast = i == 5;
          return Expanded(
            child: Row(
              children: [
                Expanded(child: _StepNode(index: i, result: results[i])),
                if (!isLast)
                  _ConnectorLine(
                    leftStatus:  results[i].status,
                    rightStatus: results[i + 1].status,
                  ),
              ],
            ),
          );
        }),
      ),
    );
  }
}

// ── Single step circle + label ─────────────────────────────────────────────────

class _StepNode extends StatelessWidget {
  final int         index;
  final PhaseResult result;

  const _StepNode({required this.index, required this.result});

  @override
  Widget build(BuildContext context) {
    final status = result.status;
    final isPending = status == PhaseStatus.pending;
    final color = status.color;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Circle
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isPending
                ? AppTheme.cardColor
                : color.withValues(alpha: 0.15),
            border: Border.all(
              color: isPending ? AppTheme.borderColor : color,
              width: 2,
            ),
          ),
          child: Center(
            child: isPending
                ? Text(
                    '${index + 1}',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.borderColor,
                    ),
                  )
                : Icon(status.icon, size: 16, color: color),
          ),
        ),
        const SizedBox(height: 4),
        // Label
        Text(
          _labels[index],
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 9,
            fontWeight: FontWeight.w600,
            color: isPending ? AppTheme.neutralColor : color,
            letterSpacing: 0.3,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

// ── Connector line between two steps ──────────────────────────────────────────

class _ConnectorLine extends StatelessWidget {
  final PhaseStatus leftStatus;
  final PhaseStatus rightStatus;

  const _ConnectorLine({
    required this.leftStatus,
    required this.rightStatus,
  });

  @override
  Widget build(BuildContext context) {
    // Line is green only if the left step has passed.
    final Color lineColor;
    if (leftStatus == PhaseStatus.pass) {
      lineColor = AppTheme.profitColor.withValues(alpha: 0.5);
    } else if (leftStatus == PhaseStatus.pending) {
      lineColor = AppTheme.borderColor.withValues(alpha: 0.4);
    } else {
      lineColor = leftStatus.color.withValues(alpha: 0.4);
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 20), // align with circle centre
      child: Container(
        height: 2,
        color: lineColor,
      ),
    );
  }
}
