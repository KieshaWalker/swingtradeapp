// =============================================================================
// features/trend_lines/models/trend_line.dart
// =============================================================================
// A saved trend line — two anchor points, a name, and nothing else computed.
// slope/intercept/accuracy are all DERIVED, never stored, so a line can never
// drift out of sync with its own two points. See migration 085 for the schema
// this mirrors and the full rationale for that choice.
// =============================================================================

import 'equity_bar.dart';

enum TrendLineKind { support, resistance, manual }
enum TrendLineSource { manual, fitted }

extension TrendLineKindExt on TrendLineKind {
  String get dbValue => name;
  static TrendLineKind fromDb(String v) => TrendLineKind.values.firstWhere(
        (k) => k.dbValue == v,
        orElse: () => TrendLineKind.manual,
      );
  String get label => switch (this) {
        TrendLineKind.support => 'Support',
        TrendLineKind.resistance => 'Resistance',
        TrendLineKind.manual => 'Manual',
      };
}

extension TrendLineSourceExt on TrendLineSource {
  String get dbValue => name;
  static TrendLineSource fromDb(String v) => TrendLineSource.values.firstWhere(
        (s) => s.dbValue == v,
        orElse: () => TrendLineSource.manual,
      );
}

class TrendLineRecord {
  final String id;
  final String ticker;
  final String name;
  final TrendLineKind kind;
  final TrendLineSource source;
  final DateTime anchor1Date;
  final double anchor1Price;
  final DateTime anchor2Date;
  final double anchor2Price;
  final DateTime createdAt;

  const TrendLineRecord({
    required this.id,
    required this.ticker,
    required this.name,
    required this.kind,
    required this.source,
    required this.anchor1Date,
    required this.anchor1Price,
    required this.anchor2Date,
    required this.anchor2Price,
    required this.createdAt,
  });

  /// Price-per-CALENDAR-day slope, for simple list-row display only. The
  /// backend recomputes the same thing internally from these same two
  /// anchors — this is not a second implementation, just the identical
  /// formula run client-side.
  double get pricePerDay {
    final days = anchor2Date.difference(anchor1Date).inDays;
    return days == 0 ? 0 : (anchor2Price - anchor1Price) / days;
  }

  /// Slope in BAR-INDEX space (price per trading day), for chart x-axis
  /// positioning — NOT the same number as [pricePerDay]. Trading days skip
  /// weekends and holidays, so a calendar-day slope misplaces the line
  /// against a bar-indexed x-axis; this maps both anchors to their nearest
  /// bar in [bars] first, mirroring routers/trend_lines.py's _nearest_index,
  /// then takes the slope in that index space — the same space the backend
  /// uses when it tracks this line's accuracy.
  double indexSlope(List<EquityBar> bars) {
    final i1 = nearestBarIndex(bars, anchor1Date);
    final i2 = nearestBarIndex(bars, anchor2Date);
    if (i2 == i1) return 0;
    return (anchor2Price - anchor1Price) / (i2 - i1);
  }

  /// Index of the bar on or before [target], or 0 if every bar is after it.
  /// Positioning only — see the header note on why this is not a second
  /// analytic, just where a stored value is drawn on the x-axis.
  static int nearestBarIndex(List<EquityBar> bars, DateTime target) {
    int idx = 0;
    for (int i = 0; i < bars.length; i++) {
      if (!bars[i].date.isAfter(target)) {
        idx = i;
      } else {
        break;
      }
    }
    return idx;
  }

  factory TrendLineRecord.fromJson(Map<String, dynamic> j) => TrendLineRecord(
        id: j['id'] as String,
        ticker: j['ticker'] as String,
        name: j['name'] as String,
        kind: TrendLineKindExt.fromDb(j['kind'] as String),
        source: TrendLineSourceExt.fromDb(j['source'] as String),
        // Plain date columns — parsed as-is, never shifted between zones.
        anchor1Date: DateTime.parse(j['anchor1_date'] as String),
        anchor1Price: (j['anchor1_price'] as num).toDouble(),
        anchor2Date: DateTime.parse(j['anchor2_date'] as String),
        anchor2Price: (j['anchor2_price'] as num).toDouble(),
        createdAt: DateTime.parse(j['created_at'] as String).toLocal(),
      );

  Map<String, dynamic> toInsertJson() => {
        'ticker': ticker,
        'name': name,
        'kind': kind.dbValue,
        'source': source.dbValue,
        'anchor1_date': toIsoDateStatic(anchor1Date),
        'anchor1_price': anchor1Price,
        'anchor2_date': toIsoDateStatic(anchor2Date),
        'anchor2_price': anchor2Price,
      };

  /// Calendar-date formatting shared by every anchor field on this model and
  /// by the providers that build the same shape for insert/accuracy calls —
  /// one implementation so a save and an accuracy check always agree on what
  /// date a DateTime maps to, regardless of local timezone.
  static String toIsoDateStatic(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

/// One candidate from POST /trend-lines/suggest — not yet saved.
class TrendLineCandidate {
  final DateTime anchor1Date;
  final double anchor1Price;
  final DateTime anchor2Date;
  final double anchor2Price;
  final int touches;
  final int spanBars;
  final double tightness;
  final double score;

  const TrendLineCandidate({
    required this.anchor1Date,
    required this.anchor1Price,
    required this.anchor2Date,
    required this.anchor2Price,
    required this.touches,
    required this.spanBars,
    required this.tightness,
    required this.score,
  });

  factory TrendLineCandidate.fromJson(Map<String, dynamic> j) =>
      TrendLineCandidate(
        anchor1Date: DateTime.parse(j['anchor1_date'] as String),
        anchor1Price: (j['anchor1_price'] as num).toDouble(),
        anchor2Date: DateTime.parse(j['anchor2_date'] as String),
        anchor2Price: (j['anchor2_price'] as num).toDouble(),
        touches: j['touches'] as int,
        spanBars: j['span_bars'] as int,
        tightness: (j['tightness'] as num).toDouble(),
        score: (j['score'] as num).toDouble(),
      );
}

/// Result of POST /trend-lines/accuracy for one saved line.
class TrendLineAccuracy {
  final int barsChecked;
  final int touches;
  final int violations;
  final DateTime? firstViolationDate;
  final double? maxDeviationAtr;
  /// 'holding' | 'broken' | null (manual line — no side is assumed, so no
  /// verdict is given; this is NOT the same as "holding").
  final String? status;

  const TrendLineAccuracy({
    required this.barsChecked,
    required this.touches,
    required this.violations,
    this.firstViolationDate,
    this.maxDeviationAtr,
    this.status,
  });

  factory TrendLineAccuracy.fromJson(Map<String, dynamic> j) =>
      TrendLineAccuracy(
        barsChecked: j['bars_checked'] as int,
        touches: j['touches'] as int,
        violations: j['violations'] as int,
        firstViolationDate: j['first_violation_date'] == null
            ? null
            : DateTime.parse(j['first_violation_date'] as String),
        maxDeviationAtr: (j['max_deviation_atr'] as num?)?.toDouble(),
        status: j['status'] as String?,
      );
}
