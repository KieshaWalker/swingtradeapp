// =============================================================================
// widgets/chart/chart_card.dart
// =============================================================================
// Shared chrome for the analytics charts (expected move, realized vol, GEX,
// IV history, skew, …). One consistent card so each chart widget only supplies
// its plot plus a few descriptors instead of re-implementing the container,
// header, segmented control, legend and empty states.
//
//   ChartCard               — card: header (title + actions), optional stat
//                             strip, optional segmented control, divider,
//                             fixed-height body, optional legend.
//   ChartSegmentedTabs      — pill segmented control (replaces Material TabBar).
//   ChartStatChip           — compact stat pill for the header strip.
//   ChartLegendItem / row   — legend swatches.
//   ChartEmptyState         — icon + title + message body.
//   ChartMessage            — centred loading / error body.
//   ChartFullScreenScaffold — full-screen page wrapper for an expanded chart.
//   ChartPalette            — shared series colours.
//   fmtPct                  — shared "23.4%" / "—" formatter.
// =============================================================================

import 'package:flutter/material.dart';
import '../../theme.dart';

// ── Shared palette & helpers ────────────────────────────────────────────────

/// Series colours shared across the analytics charts.
abstract final class ChartPalette {
  static const green = Color(0xFF4ADE80); // ±1σ / RV 21d
  static const yellow = Color(0xFFFBBF24); // ±2σ / RV 5d
  static const red = Color(0xFFFF7B72); // ±3σ
  static const indigo = Color(0xFF818CF8); // IV overlay
  static const white = Colors.white; // RV 1d / spot
}

/// "23.4%" / "—" — the formatter every vol chart was re-declaring.
String fmtPct(double? v, {int decimals = 1}) =>
    v == null ? '—' : '${(v * 100).toStringAsFixed(decimals)}%';

/// Uppercase section-label style shared by every analytics card header.
const kChartTitleStyle = TextStyle(
  color: AppTheme.neutralColor,
  fontSize: 11,
  fontWeight: FontWeight.w700,
  letterSpacing: 1.0,
);

// ── Card scaffold ───────────────────────────────────────────────────────────

class ChartCard extends StatelessWidget {
  /// Uppercase section label, e.g. 'EXPECTED MOVE'.
  final String title;

  /// Trailing header icons (info, fullscreen, …).
  final List<Widget> actions;

  /// Optional stat strip under the title — typically a `Wrap` of [ChartStatChip].
  final Widget? stats;

  /// Optional segmented control (e.g. DAILY / MONTHLY) above the divider.
  final Widget? segmentedControl;

  /// Height of the chart body.
  final double height;

  /// Chart body — owns its own loading / error / data states.
  final Widget child;

  /// Legend swatches rendered at the bottom.
  final List<ChartLegendItem> legend;

  const ChartCard({
    super.key,
    required this.title,
    required this.height,
    required this.child,
    this.actions = const [],
    this.stats,
    this.segmentedControl,
    this.legend = const [],
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header: title + actions ──────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 0),
            child: ChartCardHeader(title: title, actions: actions),
          ),

          // ── Stat strip ───────────────────────────────────────────────────
          if (stats != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
              child: stats!,
            ),

          // ── Segmented control / spacing ──────────────────────────────────
          if (segmentedControl != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: segmentedControl!,
            )
          else
            const SizedBox(height: 12),

          const Divider(height: 1, color: AppTheme.borderColor),

          // ── Body ─────────────────────────────────────────────────────────
          SizedBox(height: height, child: child),

          // ── Legend ───────────────────────────────────────────────────────
          if (legend.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
              child: ChartLegendRow(items: legend),
            ),
        ],
      ),
    );
  }
}

// ── Shared header ───────────────────────────────────────────────────────────

/// Title + trailing actions row shared by [ChartCard] and [AnalyticsCard].
/// Padding-agnostic — the host card supplies the surrounding insets.
class ChartCardHeader extends StatelessWidget {
  final String title;
  final List<Widget> actions;
  const ChartCardHeader({
    super.key,
    required this.title,
    this.actions = const [],
  });

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Expanded(child: Text(title, style: kChartTitleStyle)),
          ...actions,
        ],
      );
}

// ── Analytics card ──────────────────────────────────────────────────────────

/// Lighter sibling of [ChartCard] for interpretation-heavy cards (GEX, skew,
/// VVol, IV rank, vanna/charm): the same card shell + header, but a free-form
/// body (stat grids + plots + prose) instead of a fixed-height plot + legend.
class AnalyticsCard extends StatelessWidget {
  final String title;

  /// Trailing header widgets — typically a single status badge.
  final List<Widget> actions;

  /// Body widgets rendered below the header (caller controls spacing).
  final List<Widget> children;

  final EdgeInsetsGeometry padding;

  const AnalyticsCard({
    super.key,
    required this.title,
    required this.children,
    this.actions = const [],
    this.padding = const EdgeInsets.all(16),
  });

  @override
  Widget build(BuildContext context) => Container(
        padding: padding,
        decoration: BoxDecoration(
          color: AppTheme.cardColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.borderColor),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ChartCardHeader(title: title, actions: actions),
            ...children,
          ],
        ),
      );
}

// ── Header icon button ──────────────────────────────────────────────────────

class ChartActionButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  const ChartActionButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) => IconButton(
        icon: Icon(icon, size: 17, color: AppTheme.neutralColor),
        padding: const EdgeInsets.all(6),
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(),
        tooltip: tooltip,
        onPressed: onPressed,
      );
}

// ── Segmented control ───────────────────────────────────────────────────────

class ChartSegmentedTabs extends StatelessWidget {
  final List<String> labels;
  final int selected;
  final ValueChanged<int> onChanged;
  const ChartSegmentedTabs({
    super.key,
    required this.labels,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: AppTheme.elevatedColor,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: AppTheme.borderColor.withValues(alpha: 0.5)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(labels.length, (i) {
            final isSel = i == selected;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => onChanged(i),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                curve: Curves.easeOut,
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 7),
                decoration: BoxDecoration(
                  color: isSel
                      ? AppTheme.profitColor.withValues(alpha: 0.18)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Text(
                  labels[i],
                  style: TextStyle(
                    color: isSel ? AppTheme.profitColor : AppTheme.neutralColor,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            );
          }),
        ),
      ),
    );
  }
}

// ── Stat chip ───────────────────────────────────────────────────────────────

class ChartStatChip extends StatelessWidget {
  final String label;
  final String value;

  /// Optional accent dot (ties the stat to a series colour).
  final Color? dotColor;
  const ChartStatChip({
    super.key,
    required this.label,
    required this.value,
    this.dotColor,
  });

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: AppTheme.elevatedColor,
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: AppTheme.borderColor.withValues(alpha: 0.4)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (dotColor != null) ...[
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
            ],
            Text(
              label,
              style: const TextStyle(
                color: AppTheme.neutralColor,
                fontSize: 10,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 5),
            Text(
              value,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                fontFamily: 'monospace',
              ),
            ),
          ],
        ),
      );
}

// ── Legend ──────────────────────────────────────────────────────────────────

class ChartLegendItem {
  final Color color;
  final String label;

  /// Render the swatch as a dashed line (matches dashed chart series).
  final bool dashed;
  const ChartLegendItem(this.color, this.label, {this.dashed = false});
}

class ChartLegendRow extends StatelessWidget {
  final List<ChartLegendItem> items;
  const ChartLegendRow({super.key, required this.items});

  @override
  Widget build(BuildContext context) => Wrap(
        alignment: WrapAlignment.center,
        spacing: 8,
        runSpacing: 6,
        children: [for (final it in items) _LegendChip(item: it)],
      );
}

class _LegendChip extends StatelessWidget {
  final ChartLegendItem item;
  const _LegendChip({required this.item});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: item.color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _Swatch(color: item.color, dashed: item.dashed),
            const SizedBox(width: 6),
            Text(
              item.label,
              style: const TextStyle(color: Colors.white70, fontSize: 10),
            ),
          ],
        ),
      );
}

class _Swatch extends StatelessWidget {
  final Color color;
  final bool dashed;
  const _Swatch({required this.color, required this.dashed});

  @override
  Widget build(BuildContext context) {
    if (!dashed) {
      return Container(
        width: 14,
        height: 3,
        decoration:
            BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
      );
    }
    // Two short segments to read as a dashed line.
    Widget seg() => Container(
          width: 5,
          height: 3,
          decoration:
              BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
        );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [seg(), const SizedBox(width: 3), seg()],
    );
  }
}

// ── State bodies ────────────────────────────────────────────────────────────

/// Centred single-line message — used for loading and error bodies.
class ChartMessage extends StatelessWidget {
  final String? text;
  final bool spinner;
  const ChartMessage._({this.text, this.spinner = false});

  const ChartMessage.loading() : this._(spinner: true);
  const ChartMessage.error([String message = 'Error loading data'])
      : this._(text: message);

  @override
  Widget build(BuildContext context) => Center(
        child: spinner
            ? const CircularProgressIndicator(strokeWidth: 2)
            : Text(
                text ?? '',
                style: const TextStyle(color: AppTheme.neutralColor),
              ),
      );
}

/// Icon + title + message empty body.
class ChartEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  const ChartEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
  });

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 36, color: AppTheme.neutralColor.withValues(alpha: 0.5)),
            const SizedBox(height: 12),
            Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              message,
              style: const TextStyle(color: AppTheme.neutralColor, fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
}

// ── Full-screen page ────────────────────────────────────────────────────────

class ChartFullScreenScaffold extends StatelessWidget {
  final String title;
  final String hint;
  final List<ChartLegendItem> legend;

  /// Expanded chart area — typically a `PannableChart(showZoomButtons: true)`.
  final Widget child;

  const ChartFullScreenScaffold({
    super.key,
    required this.title,
    required this.child,
    this.legend = const [],
    this.hint = 'Pinch or use buttons to zoom · Double-tap to reset',
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.cardColor,
      appBar: AppBar(
        backgroundColor: AppTheme.cardColor,
        title: Text(
          title,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Center(
              child: Text(
                hint,
                style:
                    const TextStyle(color: AppTheme.neutralColor, fontSize: 10),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          const Divider(height: 1, color: AppTheme.borderColor),
          Expanded(child: child),
          if (legend.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: ChartLegendRow(items: legend),
            ),
        ],
      ),
    );
  }
}
