// =============================================================================
// widgets/chart/chart_axes.dart
// =============================================================================
// Shared fl_chart axis builders, so each bar/line chart only describes its
// data instead of re-implementing title widgets and label-skipping rules.
// =============================================================================

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import '../../theme.dart';
import '../../utils/formatters.dart';

/// Hidden axis — the boilerplate every chart re-declares for top/left/right.
const kNoAxisTitles = AxisTitles(sideTitles: SideTitles(showTitles: false));

/// Bottom axis for charts whose groups are indexed by sorted yyyymm keys
/// (e.g. 202601). Skips alternate labels when more than six months are shown
/// and prefixes the year on January / the first bar.
AxisTitles monthKeyBottomTitles(List<int> monthKeys) => AxisTitles(
      sideTitles: SideTitles(
        showTitles: true,
        getTitlesWidget: (v, _) {
          final idx = v.toInt();
          if (idx < 0 || idx >= monthKeys.length) {
            return const SizedBox.shrink();
          }
          if (monthKeys.length > 6 && idx % 2 != 0) {
            return const SizedBox.shrink();
          }
          final key = monthKeys[idx];
          final year = key ~/ 100;
          final month = key % 100;
          final label = (month == 1 || idx == 0)
              ? "${kMonthAbbr[month]} '${year % 100}"
              : kMonthAbbr[month];
          return Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              label,
              style: const TextStyle(
                  color: AppTheme.neutralColor, fontSize: 9),
            ),
          );
        },
      ),
    );
