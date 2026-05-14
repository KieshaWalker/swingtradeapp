// =============================================================================
// vol_surface/widgets/vol_smile_chart.dart
// Vol smile — one line per DTE using fl_chart LineChart
// =============================================================================
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import '../models/vol_surface_models.dart';

class VolSmileChart extends StatefulWidget {
  final List<VolPoint> points;
  final double? spotPrice;
  final String ivMode;

  const VolSmileChart({
    super.key,
    required this.points,
    this.spotPrice,
    required this.ivMode,
  });

  @override
  State<VolSmileChart> createState() => _VolSmileChartState();
}

class _VolSmileChartState extends State<VolSmileChart> {
  late Set<int> _visibleDtes;

  static const _palette = [
    Color(0xFF60a5fa), // blue
    Color(0xFF4ade80), // green
    Color(0xFFfbbf24), // amber
    Color(0xFFf472b6), // pink
    Color(0xFF818cf8), // indigo
    Color(0xFFfb923c), // orange
    Color(0xFF34d399), // teal
    Color(0xFFa78bfa), // violet
  ];

  @override
  void initState() {
    super.initState();
    _initVisible();
  }

  @override
  void didUpdateWidget(VolSmileChart old) {
    super.didUpdateWidget(old);
    if (old.points != widget.points) _initVisible();
  }

  void _initVisible() {
    final dtes = widget.points.map((p) => p.dte).toSet().toList()..sort();
    _visibleDtes = dtes.take(8).toSet();
  }

  static String _dteGroup(int dte) {
    if (dte < 30) return '<30d';
    if (dte <= 90) return '30–90d';
    return '>90d';
  }

  // Tapping a group header selects/deselects all DTEs in that group.
  Widget _groupHeader(String label, List<int> groupDtes, {required bool isFirst}) {
    final anyVisible = groupDtes.any((d) => _visibleDtes.contains(d));
    return GestureDetector(
      onTap: () => setState(() {
        if (anyVisible) {
          _visibleDtes.removeAll(groupDtes);
        } else {
          _visibleDtes.addAll(groupDtes);
        }
      }),
      child: Container(
        margin: EdgeInsets.only(left: isFirst ? 0 : 2, right: 6),
        padding: EdgeInsets.only(left: isFirst ? 0 : 6),
        decoration: isFirst
            ? null
            : const BoxDecoration(
                border: Border(
                    left: BorderSide(color: Color(0xFF374151)))),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              color: anyVisible
                  ? const Color(0xFF6b7280)
                  : const Color(0xFF374151),
              fontSize: 9,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
              fontFamily: 'monospace',
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final allDtes = widget.points.map((p) => p.dte).toSet().toList()..sort();
    if (allDtes.isEmpty) {
      return const Center(
          child: Text('No data', style: TextStyle(color: Colors.white38)));
    }

    // Pre-compute groups so headers know their member DTEs.
    final groupMembers = <String, List<int>>{};
    for (final dte in allDtes) {
      groupMembers.putIfAbsent(_dteGroup(dte), () => []).add(dte);
    }
    final multiGroup = groupMembers.length > 1;

    // Build line chart bars (palette index tied to allDtes position).
    final bars = <LineChartBarData>[];
    for (var i = 0; i < allDtes.length; i++) {
      final dte = allDtes[i];
      if (!_visibleDtes.contains(dte)) continue;
      final spots = widget.points
          .where((p) => p.dte == dte)
          .map((p) {
            final iv = p.iv(widget.ivMode, widget.spotPrice);
            return iv != null ? FlSpot(p.strike, iv * 100) : null;
          })
          .whereType<FlSpot>()
          .toList()
        ..sort((a, b) => a.x.compareTo(b.x));
      if (spots.isEmpty) continue;
      bars.add(LineChartBarData(
        spots: spots,
        color: _palette[i % _palette.length],
        barWidth: 2,
        isCurved: true,
        curveSmoothness: 0.3,
        dotData: const FlDotData(show: false),
        belowBarData: BarAreaData(show: false),
      ));
    }

    // Axis bounds
    double minX = double.infinity, maxX = double.negativeInfinity;
    double minY = double.infinity, maxY = double.negativeInfinity;
    for (final b in bars) {
      for (final s in b.spots) {
        if (s.x < minX) minX = s.x;
        if (s.x > maxX) maxX = s.x;
        if (s.y < minY) minY = s.y;
        if (s.y > maxY) maxY = s.y;
      }
    }
    if (!minX.isFinite) minX = 0;
    if (!maxX.isFinite) maxX = 1;
    if (!minY.isFinite) minY = 0;
    if (!maxY.isFinite) maxY = 1;
    final padY = (maxY - minY) * 0.1;

    // Build chip strip: group headers (when multi-group) + individual chips.
    // Palette index i stays tied to allDtes[i] so chip and line colors match.
    final chipChildren = <Widget>[];
    String? lastGroup;
    bool firstGroup = true;
    for (var i = 0; i < allDtes.length; i++) {
      final dte = allDtes[i];
      final grp = _dteGroup(dte);
      if (multiGroup && grp != lastGroup) {
        lastGroup = grp;
        chipChildren.add(
            _groupHeader(grp, groupMembers[grp]!, isFirst: firstGroup));
        firstGroup = false;
      }
      chipChildren.add(Padding(
        padding: const EdgeInsets.only(right: 6),
        child: FilterChip(
          label: Text('${dte}d', style: const TextStyle(fontSize: 11)),
          selected: _visibleDtes.contains(dte),
          selectedColor: _palette[i % _palette.length].withValues(alpha: 0.25),
          checkmarkColor: _palette[i % _palette.length],
          side: BorderSide(
              color: _palette[i % _palette.length].withValues(alpha: 0.5)),
          backgroundColor: const Color(0xFF1a1f2e),
          labelStyle: TextStyle(
            color: _visibleDtes.contains(dte)
                ? _palette[i % _palette.length]
                : Colors.white38,
          ),
          onSelected: (v) => setState(() {
            if (v) {
              _visibleDtes.add(dte);
            } else {
              _visibleDtes.remove(dte);
            }
          }),
        ),
      ));
    }

    return Column(
      children: [
        SizedBox(
          height: 40,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            children: chipChildren,
          ),
        ),
        Expanded(
          child: bars.isEmpty
              ? const Center(
                  child: Text('Select at least one DTE',
                      style: TextStyle(color: Colors.white38)))
              : Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 24, 8),
                  child: LineChart(
                    LineChartData(
                      minX: minX,
                      maxX: maxX,
                      minY: (minY - padY).clamp(0, double.infinity),
                      maxY: maxY + padY,
                      lineBarsData: bars,
                      extraLinesData: widget.spotPrice != null
                          ? ExtraLinesData(verticalLines: [
                              VerticalLine(
                                x: widget.spotPrice!,
                                color: const Color(0xFFfbbf24),
                                strokeWidth: 1,
                                dashArray: [4, 4],
                                label: VerticalLineLabel(
                                  show: true,
                                  alignment: Alignment.topRight,
                                  style: const TextStyle(
                                      color: Color(0xFFfbbf24),
                                      fontSize: 9,
                                      fontFamily: 'monospace'),
                                  labelResolver: (_) =>
                                      ' \$${widget.spotPrice!.toStringAsFixed(0)}',
                                ),
                              ),
                            ])
                          : null,
                      gridData: FlGridData(
                        show: true,
                        getDrawingHorizontalLine: (_) => const FlLine(
                            color: Color(0xFF1f2937), strokeWidth: 0.5),
                        getDrawingVerticalLine: (_) => const FlLine(
                            color: Color(0xFF1f2937), strokeWidth: 0.5),
                      ),
                      borderData: FlBorderData(
                        show: true,
                        border: Border.all(
                            color: const Color(0xFF374151), width: 0.5),
                      ),
                      titlesData: FlTitlesData(
                        leftTitles: AxisTitles(
                          axisNameSize: 16,
                          axisNameWidget: const Text('IV %',
                              style: TextStyle(
                                  color: Color(0xFFa09fc8),
                                  fontSize: 10,
                                  fontFamily: 'monospace',
                                  fontWeight: FontWeight.w600)),
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 44,
                            getTitlesWidget: (v, _) => Text(
                              '${v.toStringAsFixed(1)}%',
                              style: const TextStyle(
                                  color: Color(0xFF9ca3af),
                                  fontSize: 9,
                                  fontFamily: 'monospace'),
                            ),
                          ),
                        ),
                        bottomTitles: AxisTitles(
                          axisNameSize: 16,
                          axisNameWidget: const Text('Strike Price',
                              style: TextStyle(
                                  color: Color(0xFFa09fc8),
                                  fontSize: 10,
                                  fontFamily: 'monospace',
                                  fontWeight: FontWeight.w600)),
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 28,
                            getTitlesWidget: (v, _) => Text(
                              '\$${v == v.truncateToDouble() ? v.toInt().toString() : v.toStringAsFixed(1)}',
                              style: const TextStyle(
                                  color: Color(0xFF9ca3af),
                                  fontSize: 9,
                                  fontFamily: 'monospace'),
                            ),
                          ),
                        ),
                        rightTitles: const AxisTitles(
                            sideTitles: SideTitles(showTitles: false)),
                        topTitles: const AxisTitles(
                            sideTitles: SideTitles(showTitles: false)),
                      ),
                      lineTouchData: LineTouchData(
                        touchTooltipData: LineTouchTooltipData(
                          getTooltipColor: (_) => const Color(0xFF111827),
                          getTooltipItems: (spots) => spots
                              .map((s) => LineTooltipItem(
                                    '\$${s.x.toStringAsFixed(0)}  ${s.y.toStringAsFixed(2)}%',
                                    TextStyle(
                                        color: s.bar.color,
                                        fontSize: 11,
                                        fontFamily: 'monospace'),
                                  ))
                              .toList(),
                        ),
                      ),
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}
