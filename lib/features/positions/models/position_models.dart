// =============================================================================
// features/positions/models/position_models.dart
// =============================================================================
import 'package:uuid/uuid.dart';

enum LegType { call, put, underlying }

enum LegStatus { open, closed }

enum SnapshotType { entry, eod, exit }

class LegSnapshot {
  final String id;
  final String legId;
  final DateTime snapshotDate;
  final SnapshotType snapshotType;
  final double? underlyingPrice;
  final double? marketPrice;
  final double? bsTheo;
  final double? sabrTheo;
  final double? hestonTheo;
  final double? modelTheo;
  final double? delta;
  final double? gamma;
  final double? theta;
  final double? vega;
  final double? rho;
  final DateTime createdAt;

  LegSnapshot({
    required this.id,
    required this.legId,
    required this.snapshotDate,
    required this.snapshotType,
    this.underlyingPrice,
    this.marketPrice,
    this.bsTheo,
    this.sabrTheo,
    this.hestonTheo,
    this.modelTheo,
    this.delta,
    this.gamma,
    this.theta,
    this.vega,
    this.rho,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  factory LegSnapshot.fromSupabase(Map<String, dynamic> row) => LegSnapshot(
        id: row['id'] as String,
        legId: row['leg_id'] as String,
        snapshotDate: DateTime.parse(row['snapshot_date'] as String),
        snapshotType: SnapshotType.values.byName(row['snapshot_type'] as String),
        underlyingPrice: (row['underlying_price'] as num?)?.toDouble(),
        marketPrice: (row['market_price'] as num?)?.toDouble(),
        bsTheo: (row['bs_theo'] as num?)?.toDouble(),
        sabrTheo: (row['sabr_theo'] as num?)?.toDouble(),
        hestonTheo: (row['heston_theo'] as num?)?.toDouble(),
        modelTheo: (row['model_theo'] as num?)?.toDouble(),
        delta: (row['delta'] as num?)?.toDouble(),
        gamma: (row['gamma'] as num?)?.toDouble(),
        theta: (row['theta'] as num?)?.toDouble(),
        vega: (row['vega'] as num?)?.toDouble(),
        rho: (row['rho'] as num?)?.toDouble(),
        createdAt: DateTime.parse(row['created_at'] as String),
      );

  Map<String, dynamic> toSupabaseInsert() => {
        'id': id,
        'leg_id': legId,
        'snapshot_date': snapshotDate.toIso8601String().substring(0, 10),
        'snapshot_type': snapshotType.name,
        if (underlyingPrice != null) 'underlying_price': underlyingPrice,
        if (marketPrice != null) 'market_price': marketPrice,
        if (bsTheo != null) 'bs_theo': bsTheo,
        if (sabrTheo != null) 'sabr_theo': sabrTheo,
        if (hestonTheo != null) 'heston_theo': hestonTheo,
        if (modelTheo != null) 'model_theo': modelTheo,
        if (delta != null) 'delta': delta,
        if (gamma != null) 'gamma': gamma,
        if (theta != null) 'theta': theta,
        if (vega != null) 'vega': vega,
        if (rho != null) 'rho': rho,
      };
}

class PositionLeg {
  final String id;
  final LegType type;
  final String ticker;
  final double? strike;
  final String? expiry; // "YYYY-MM-DD"
  final int quantity;   // negative = short
  final double? entryPrice;
  final double? exitPrice;
  final LegStatus status;
  final DateTime? closedAt;

  const PositionLeg({
    required this.id,
    required this.type,
    required this.ticker,
    this.strike,
    this.expiry,
    required this.quantity,
    this.entryPrice,
    this.exitPrice,
    this.status = LegStatus.open,
    this.closedAt,
  });

  factory PositionLeg.createOption({
    String? id,
    required LegType type,
    required String ticker,
    required double strike,
    required String expiry,
    required int quantity,
    double? entryPrice,
  }) =>
      PositionLeg(
        id: id ?? const Uuid().v4(),
        type: type,
        ticker: ticker.toUpperCase().trim(),
        strike: strike,
        expiry: expiry,
        quantity: quantity,
        entryPrice: entryPrice,
      );

  factory PositionLeg.createUnderlying({
    String? id,
    required String ticker,
    required int quantity,
    double? entryPrice,
  }) =>
      PositionLeg(
        id: id ?? const Uuid().v4(),
        type: LegType.underlying,
        ticker: ticker.toUpperCase().trim(),
        quantity: quantity,
        entryPrice: entryPrice,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type.name,
        'ticker': ticker,
        'strike': strike,
        'expiry': expiry,
        'quantity': quantity,
        'entryPrice': entryPrice,
        'exitPrice': exitPrice,
        'status': status.name,
        'closedAt': closedAt?.toIso8601String(),
      };

  factory PositionLeg.fromJson(Map<String, dynamic> j) => PositionLeg(
        id: j['id'] as String,
        type: LegType.values.byName(j['type'] as String),
        ticker: j['ticker'] as String,
        strike: (j['strike'] as num?)?.toDouble(),
        expiry: j['expiry'] as String?,
        quantity: j['quantity'] as int,
        entryPrice: (j['entryPrice'] as num?)?.toDouble(),
        exitPrice: (j['exitPrice'] as num?)?.toDouble(),
        status: j['status'] != null
            ? LegStatus.values.byName(j['status'] as String)
            : LegStatus.open,
        closedAt: j['closedAt'] != null
            ? DateTime.parse(j['closedAt'] as String)
            : null,
      );

  factory PositionLeg.fromSupabase(Map<String, dynamic> row) => PositionLeg(
        id: row['id'] as String,
        type: LegType.values.byName(row['type'] as String),
        ticker: row['ticker'] as String,
        strike: (row['strike'] as num?)?.toDouble(),
        expiry: row['expiry'] as String?,
        quantity: row['quantity'] as int,
        entryPrice: (row['entry_price'] as num?)?.toDouble(),
        exitPrice: (row['exit_price'] as num?)?.toDouble(),
        status: row['status'] != null
            ? LegStatus.values.byName(row['status'] as String)
            : LegStatus.open,
        closedAt: row['closed_at'] != null
            ? DateTime.parse(row['closed_at'] as String)
            : null,
      );

  Map<String, dynamic> toSupabaseInsert(String positionId) => {
        'id': id,
        'position_id': positionId,
        'type': type.name,
        'ticker': ticker,
        'strike': strike,
        'expiry': expiry,
        'quantity': quantity,
        if (entryPrice != null) 'entry_price': entryPrice,
        if (exitPrice != null) 'exit_price': exitPrice,
        'status': status.name,
        if (closedAt != null) 'closed_at': closedAt!.toIso8601String(),
      };

  String get label {
    final sign = quantity > 0 ? '+' : '';
    if (type == LegType.underlying) return '$sign$quantity $ticker';
    final t = type == LegType.call ? 'C' : 'P';
    final k = strike == null
        ? '?'
        : (strike! % 1 == 0
            ? strike!.toInt().toString()
            : strike!.toStringAsFixed(1));
    final exp = expiry != null ? _shortMonth(expiry!) : '?';
    return '$sign$quantity $ticker $exp \$$k $t';
  }

  static String _shortMonth(String iso) {
    try {
      const m = [
        'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
      ];
      return m[DateTime.parse(iso).month - 1];
    } catch (_) {
      return iso.length >= 7 ? iso.substring(0, 7) : iso;
    }
  }
}

class Position {
  final String id;
  final String name;
  final List<PositionLeg> legs;

  const Position({
    required this.id,
    required this.name,
    required this.legs,
  });

  factory Position.create({required String name, required List<PositionLeg> legs}) =>
      Position(id: const Uuid().v4(), name: name, legs: legs);

  Position copyWith({String? name, List<PositionLeg>? legs}) =>
      Position(id: id, name: name ?? this.name, legs: legs ?? this.legs);

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'legs': legs.map((l) => l.toJson()).toList(),
      };

  factory Position.fromJson(Map<String, dynamic> j) => Position(
        id: j['id'] as String,
        name: j['name'] as String,
        legs: (j['legs'] as List)
            .map((l) => PositionLeg.fromJson(l as Map<String, dynamic>))
            .toList(),
      );

  factory Position.fromSupabase(Map<String, dynamic> row) => Position(
        id: row['id'] as String,
        name: row['name'] as String,
        legs: (row['position_legs'] as List? ?? [])
            .map((l) => PositionLeg.fromSupabase(l as Map<String, dynamic>))
            .toList(),
      );
}

// ── Live-enriched data ────────────────────────────────────────────────────────

class EnrichedLeg {
  final PositionLeg leg;
  final double? marketPrice;
  // Per-model theoretical prices from /fair-value/compute
  final double? bsTheo;      // Black-Scholes
  final double? sabrTheo;    // SABR smile-adjusted
  final double? hestonTheo;  // Heston (null when no reliable calibration)
  final double? modelTheo;   // Best available (Heston → SABR+correction → SABR)
  final double? contractDelta;
  final double? contractGamma;
  final double? contractTheta;
  final double? contractVega;
  final double? contractRho;

  const EnrichedLeg({
    required this.leg,
    this.marketPrice,
    this.bsTheo,
    this.sabrTheo,
    this.hestonTheo,
    this.modelTheo,
    this.contractDelta,
    this.contractGamma,
    this.contractTheta,
    this.contractVega,
    this.contractRho,
  });

  // Positive edge = selling overpriced / buying underpriced vs a given theo price
  double _edge(double? theo) {
    if (leg.type == LegType.underlying) return 0.0;
    final mp = marketPrice;
    if (mp == null || theo == null) return 0.0;
    return -leg.quantity.toDouble() * (mp - theo);
  }

  double get edgeVsBs     => _edge(bsTheo);
  double get edgeVsSabr   => _edge(sabrTheo);
  double? get edgeVsHeston => hestonTheo != null ? _edge(hestonTheo) : null;
  double get edgeVsModel  => _edge(modelTheo);
  double get positionEdge => edgeVsModel; // alias for backward compat

  double get positionDelta {
    if (leg.type == LegType.underlying) return leg.quantity * 100.0;
    return contractDelta != null ? leg.quantity * contractDelta! : 0.0;
  }

  double get positionGamma {
    if (leg.type == LegType.underlying) return 0.0;
    return contractGamma != null ? leg.quantity * contractGamma! : 0.0;
  }

  double get positionTheta {
    if (leg.type == LegType.underlying) return 0.0;
    return contractTheta != null ? leg.quantity * contractTheta! : 0.0;
  }

  double get positionVega {
    if (leg.type == LegType.underlying) return 0.0;
    return contractVega != null ? leg.quantity * contractVega! : 0.0;
  }

  double get positionRho {
    if (leg.type == LegType.underlying) return 0.0;
    return contractRho != null ? leg.quantity * contractRho! : 0.0;
  }
}

class EnrichedPosition {
  final Position position;
  final List<EnrichedLeg> legs;

  const EnrichedPosition({required this.position, required this.legs});

  double get totalEdgeVsBs    => legs.fold(0.0, (s, l) => s + l.edgeVsBs);
  double get totalEdgeVsSabr  => legs.fold(0.0, (s, l) => s + l.edgeVsSabr);
  double? get totalEdgeVsHeston {
    final hasHeston = legs.any((l) => l.edgeVsHeston != null);
    if (!hasHeston) return null;
    return legs.fold<double>(0.0, (s, l) => s + (l.edgeVsHeston ?? 0.0));
  }
  double get totalEdgeVsModel => legs.fold(0.0, (s, l) => s + l.edgeVsModel);
  double get totalEdge        => totalEdgeVsModel; // alias

  double get totalDelta => legs.fold(0.0, (s, l) => s + l.positionDelta);
  double get totalGamma => legs.fold(0.0, (s, l) => s + l.positionGamma);
  double get totalTheta => legs.fold(0.0, (s, l) => s + l.positionTheta);
  double get totalVega  => legs.fold(0.0, (s, l) => s + l.positionVega);
  double get totalRho   => legs.fold(0.0, (s, l) => s + l.positionRho);

  bool get hasLiveData => legs.any(
      (l) => l.contractDelta != null || l.leg.type == LegType.underlying);

  String get interpretation =>
      buildInterpretation(totalDelta, totalGamma, totalTheta, totalVega, totalRho);

  static String buildInterpretation(
      double delta, double gamma, double theta, double vega, double rho) {
    const t = 0.001;
    final parts = <String>[];
    if (delta.abs() > t) {
      parts.add(delta > 0
          ? 'Δ+ bullish — wants market to rise'
          : 'Δ− bearish — wants market to fall');
    }
    if (gamma.abs() > t) {
      parts.add(gamma > 0
          ? 'Γ+ wants large/fast moves'
          : 'Γ− wants slow/small moves');
    }
    if (theta.abs() > t) {
      parts.add(theta > 0 ? 'Θ+ time decay earns' : 'Θ− time decay costs');
    }
    if (vega.abs() > t) {
      parts.add(vega > 0 ? 'V+ wants IV to rise' : 'V− wants IV to fall');
    }
    if (rho.abs() > t) {
      parts.add(rho > 0 ? 'ρ+ wants rates to rise' : 'ρ− wants rates to fall');
    }
    return parts.isEmpty ? 'No active Greek exposure' : parts.join('  ·  ');
  }
}
