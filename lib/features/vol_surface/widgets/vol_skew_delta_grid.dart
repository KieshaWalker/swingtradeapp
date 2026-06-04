// =============================================================================
// vol_surface/widgets/vol_skew_delta_grid.dart
// =============================================================================
// Session-over-session vol smile comparison.
// Sections: spot header · ATM IV · Put wing −10% · Call wing +10% · Put slope
// =============================================================================
import 'package:flutter/material.dart';
import '../models/vol_surface_models.dart';

// Internal point type: moneyness % + IV
class _IvPt {
  final double mono;
  final double iv;
  const _IvPt(this.mono, this.iv);
}

class VolSkewDeltaGrid extends StatelessWidget {
  final VolSnapshot  snap;
  final VolSnapshot? prevSnap;

  const VolSkewDeltaGrid({super.key, required this.snap, this.prevSnap});

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (snap.points.isEmpty) {
      return _empty('No points loaded for ${snap.obsDateStr}');
    }
    if (prevSnap == null) {
      return _empty('${snap.obsDateStr} is the earliest available session');
    }
    if (prevSnap!.points.isEmpty) {
      return const Center(
        child: SizedBox(
          width: 20, height: 20,
          child: CircularProgressIndicator(strokeWidth: 1.5),
        ),
      );
    }

    final rows = _computeRows();
    if (rows.isEmpty) {
      return _empty('Insufficient data to compute smile comparison');
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SpotHeader(
            prevDate:  prevSnap!.obsDateStr,
            todayDate: snap.obsDateStr,
            prevSpot:  prevSnap!.spotPrice,
            todaySpot: snap.spotPrice,
          ),
          const SizedBox(height: 20),

          _sectionLabel('ATM Implied Volatility'),
          const SizedBox(height: 6),
          _SmileTable(
            prevDate:  prevSnap!.obsDateStr,
            todayDate: snap.obsDateStr,
            rows: rows.map((r) => _SmileTableRow(
              dte:        r.label,
              strike:     r.todayAtmStrike,
              prevIv:     r.prevAtm,
              todayIv:    r.todayAtm,
              deltaIv:    r.dAtm,
              oi:         r.todayAtmOI,
              volume:     r.todayAtmVol,
            )).toList(),
          ),
          const SizedBox(height: 20),

          _sectionLabel('Put Wing  ·  OTM put nearest −10% from spot'),
          const SizedBox(height: 6),
          _SmileTable(
            prevDate:  prevSnap!.obsDateStr,
            todayDate: snap.obsDateStr,
            rows: rows.map((r) => _SmileTableRow(
              dte:        r.label,
              strike:     r.todayPutStrike,
              prevIv:     r.prevPut,
              todayIv:    r.todayPut,
              deltaIv:    r.dPut,
              oi:         r.todayPutOI,
              volume:     r.todayPutVol,
            )).toList(),
          ),
          const SizedBox(height: 20),

          _sectionLabel('Call Wing  ·  OTM call nearest +10% from spot'),
          const SizedBox(height: 6),
          _SmileTable(
            prevDate:  prevSnap!.obsDateStr,
            todayDate: snap.obsDateStr,
            rows: rows.map((r) => _SmileTableRow(
              dte:        r.label,
              strike:     r.todayCallStrike,
              prevIv:     r.prevCall,
              todayIv:    r.todayCall,
              deltaIv:    r.dCall,
              oi:         r.todayCallOI,
              volume:     r.todayCallVol,
            )).toList(),
          ),
          const SizedBox(height: 20),

          _sectionLabel('Put Skew Slope  ·  (put −10% IV) − (ATM IV)'),
          const SizedBox(height: 6),
          _SlopeTable(
            prevDate:  prevSnap!.obsDateStr,
            todayDate: snap.obsDateStr,
            rows: rows,
          ),
        ],
      ),
    );
  }

  // ── Computation ────────────────────────────────────────────────────────────

  List<_SkewRow> _computeRows() {
    final tSmile = _buildSmile(snap.points,      snap.spotPrice);
    final pSmile = _buildSmile(prevSnap!.points, prevSnap!.spotPrice);

    final tDtes = tSmile.keys.toList()..sort();
    final pDtes  = pSmile.keys.toList();

    final rows = <_SkewRow>[];
    for (final td in tDtes) {
      final pd = _matchDte(td, pDtes);
      if (pd == null) continue;

      final tPts = tSmile[td]!;
      final pPts = pSmile[pd]!;
      if (tPts.length < 3 || pPts.length < 3) continue;

      final tAtm  = _interp(tPts,   0.0);
      final pAtm  = _interp(pPts,   0.0);
      final tPut  = _interp(tPts, -10.0);
      final pPut  = _interp(pPts, -10.0);
      final tCall = _interp(tPts, 10.0);
      final pCall = _interp(pPts, 10.0);

      if ([tAtm, pAtm, tPut, pPut, tCall, pCall].any((v) => v == null)) continue;

      // Nearest actual points for strike / OI / volume
      final tAtmPt  = _nearestPoint(snap.points,      snap.spotPrice,   0.0);
      final tPutPt  = _nearestPoint(snap.points,      snap.spotPrice, -10.0);
      final tCallPt = _nearestPoint(snap.points,      snap.spotPrice, 10.0);

      rows.add(_SkewRow(
        label:          _dteLabel(td),
        todayAtm:       tAtm!,    prevAtm:  pAtm!,
        todayPut:       tPut!,    prevPut:  pPut!,
        todayCall:      tCall!,   prevCall: pCall!,
        todayAtmStrike:  tAtmPt?.strike,
        todayPutStrike:  tPutPt?.strike,
        todayCallStrike: tCallPt?.strike,
        todayAtmOI:  _totalOI(tAtmPt),
        todayAtmVol: _totalVol(tAtmPt),
        todayPutOI:  _totalOI(tPutPt),
        todayPutVol: _totalVol(tPutPt),
        todayCallOI:  _totalOI(tCallPt),
        todayCallVol: _totalVol(tCallPt),
      ));
    }
    return rows;
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  static Map<int, List<_IvPt>> _buildSmile(
      List<VolPoint> pts, double? spot) {
    if (spot == null || spot <= 0) return {};
    final m = <int, List<_IvPt>>{};
    for (final p in pts) {
      double? iv;
      if (p.strike > spot) {
        iv = p.callIv;
      } else if (p.strike < spot) {
        iv = p.putIv;
      } else {
        iv = (p.callIv != null && p.putIv != null)
            ? (p.callIv! + p.putIv!) / 2
            : (p.callIv ?? p.putIv);
      }
      if (iv == null || iv <= 0) continue;
      final mono = (p.strike / spot - 1) * 100.0;
      (m[p.dte] ??= []).add(_IvPt(mono, iv));
    }
    for (final v in m.values) {
      v.sort((a, b) => a.mono.compareTo(b.mono));
    }
    return m;
  }

  static double? _interp(List<_IvPt> pts, double target) {
    if (pts.isEmpty) return null;
    final below = pts.where((p) => p.mono <= target).toList();
    final above = pts.where((p) => p.mono >= target).toList();
    if (below.isEmpty || above.isEmpty) {
      return pts.reduce((a, b) =>
          (a.mono - target).abs() < (b.mono - target).abs() ? a : b).iv;
    }
    final b = below.last;
    final a = above.first;
    if (b.mono == a.mono) return b.iv;
    final t = (target - b.mono) / (a.mono - b.mono);
    return b.iv + t * (a.iv - b.iv);
  }

  static VolPoint? _nearestPoint(
      List<VolPoint> pts, double? spot, double targetMono) {
    if (spot == null || spot <= 0 || pts.isEmpty) return null;
    VolPoint? best;
    double bestDist = double.infinity;
    for (final p in pts) {
      final mono = (p.strike / spot - 1) * 100.0;
      final dist = (mono - targetMono).abs();
      if (dist < bestDist) { bestDist = dist; best = p; }
    }
    return best;
  }

  static int? _totalOI(VolPoint? p) {
    if (p == null) return null;
    final c = p.callOI ?? 0;
    final x = p.putOI  ?? 0;
    return (c + x) > 0 ? c + x : null;
  }

  static int? _totalVol(VolPoint? p) {
    if (p == null) return null;
    final c = p.callVolume ?? 0;
    final x = p.putVolume  ?? 0;
    return (c + x) > 0 ? c + x : null;
  }

  static int? _matchDte(int dte, List<int> others) {
    final c = others.where((d) => (d - dte).abs() <= 3).toList();
    if (c.isEmpty) return null;
    return c.reduce((a, b) => (a - dte).abs() < (b - dte).abs() ? a : b);
  }

  static String _dteLabel(int dte) {
    if (dte <= 5)  return 'weekly   ${dte}d';
    if (dte <= 14) return 'near     ${dte}d';
    if (dte <= 45) return 'monthly  ${dte}d';
    if (dte <= 95) return 'qtrly    ${dte}d';
    return                 'far      ${dte}d';
  }

  static Widget _empty(String msg) => Center(
        child: Text(msg,
            textAlign: TextAlign.center,
            style: const TextStyle(
                color: Color(0xFF4b5563),
                fontSize: 12,
                fontFamily: 'monospace')));

  static Widget _sectionLabel(String text) => Text(
        text.toUpperCase(),
        style: const TextStyle(
            color:        Color(0xFF6b7280),
            fontSize:     9,
            fontWeight:   FontWeight.w700,
            letterSpacing: 1.0,
            fontFamily:   'monospace'));
}

// ── Data model ─────────────────────────────────────────────────────────────────

class _SkewRow {
  final String  label;
  final double  todayAtm,  prevAtm;
  final double  todayPut,  prevPut;
  final double  todayCall, prevCall;
  final double? todayAtmStrike, todayPutStrike, todayCallStrike;
  final int?    todayAtmOI, todayAtmVol;
  final int?    todayPutOI, todayPutVol;
  final int?    todayCallOI, todayCallVol;

  const _SkewRow({
    required this.label,
    required this.todayAtm,  required this.prevAtm,
    required this.todayPut,  required this.prevPut,
    required this.todayCall, required this.prevCall,
    this.todayAtmStrike, this.todayPutStrike, this.todayCallStrike,
    this.todayAtmOI,  this.todayAtmVol,
    this.todayPutOI,  this.todayPutVol,
    this.todayCallOI, this.todayCallVol,
  });

  double get dAtm   => todayAtm  - prevAtm;
  double get dPut   => todayPut  - prevPut;
  double get dCall  => todayCall - prevCall;
  double get todaySlope => todayPut - todayAtm;
  double get prevSlope  => prevPut  - prevAtm;
  double get dSlope     => todaySlope - prevSlope;
}

class _SmileTableRow {
  final String  dte;
  final double? strike;
  final double  prevIv, todayIv, deltaIv;
  final int?    oi, volume;

  const _SmileTableRow({
    required this.dte,
    this.strike,
    required this.prevIv,
    required this.todayIv,
    required this.deltaIv,
    this.oi,
    this.volume,
  });
}

// ── Shared constants ───────────────────────────────────────────────────────────

const _kBorder  = Color(0xFF1f2937);
const _kHeaderBg = Color(0xFF0d1117);
const _kAltBg    = Color(0x08ffffff);
const _kText     = Color(0xFFd1d5db);
const _kDim      = Color(0xFF6b7280);

const TextStyle _kMono = TextStyle(
    fontFamily: 'monospace', fontSize: 11, color: _kText);
const TextStyle _kMonoHdr = TextStyle(
    fontFamily: 'monospace', fontSize: 9,  color: _kDim,
    fontWeight: FontWeight.w700, letterSpacing: 0.5);

String _fmtIv(double v, {bool signed = false}) {
  final pct = (v * 100).toStringAsFixed(2);
  if (!signed) return '$pct%';
  return v >= 0 ? '+$pct%' : '$pct%';
}

String _fmtInt(int v) {
  if (v >= 1000000) return '${(v / 1000000).toStringAsFixed(1)}M';
  if (v >= 1000)    return '${(v / 1000).toStringAsFixed(1)}K';
  return v.toString();
}

// Returns highlight color for the Δ cell background; null = no highlight.
Color? _deltaHighlight(double delta) {
  final d = delta * 100; // in pp
  if (d >  2.0) return const Color(0x30f97316); // orange
  if (d >  0.5) return const Color(0x25fbbf24); // amber
  if (d < -2.0) return const Color(0x3060a5fa); // blue
  if (d < -0.5) return const Color(0x2093c5fd); // light blue
  return null;
}

Color _deltaTextColor(double delta) {
  final d = delta * 100;
  if (d >  0.5) return const Color(0xFFfbbf24);
  if (d < -0.5) return const Color(0xFF93c5fd);
  return _kText;
}

// ── Spot header ────────────────────────────────────────────────────────────────

class _SpotHeader extends StatelessWidget {
  final String prevDate, todayDate;
  final double? prevSpot, todaySpot;

  const _SpotHeader({
    required this.prevDate,  required this.todayDate,
    required this.prevSpot,  required this.todaySpot,
  });

  @override
  Widget build(BuildContext context) {
    if (prevSpot == null || todaySpot == null) return const SizedBox.shrink();
    final delta = todaySpot! - prevSpot!;
    final pct   = delta / prevSpot! * 100;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: _kHeaderBg,
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(children: [
        _spotCol(prevDate,  prevSpot!),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12),
          child: Icon(Icons.east_rounded, size: 13, color: _kDim),
        ),
        _spotCol(todayDate, todaySpot!),
        const SizedBox(width: 16),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            '${delta >= 0 ? '+' : ''}\$${delta.toStringAsFixed(2)}',
            style: TextStyle(
              fontFamily: 'monospace', fontSize: 13, fontWeight: FontWeight.w700,
              color: delta >= 0 ? const Color(0xFF4ade80) : const Color(0xFFf87171),
            ),
          ),
          Text(
            '${pct >= 0 ? '+' : ''}${pct.toStringAsFixed(2)}%',
            style: TextStyle(
              fontFamily: 'monospace', fontSize: 10,
              color: delta >= 0 ? const Color(0xFF4ade80) : const Color(0xFFf87171),
            ),
          ),
        ]),
      ]),
    );
  }

  Widget _spotCol(String date, double price) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(date,  style: const TextStyle(fontFamily: 'monospace', fontSize: 9,  color: _kDim)),
      Text('\$${price.toStringAsFixed(2)}',
          style: const TextStyle(fontFamily: 'monospace', fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFFf9fafb))),
    ],
  );
}

// ── Smile section table (ATM / Put / Call) ─────────────────────────────────────
// Columns: DTE · Strike · Prev IV · Today IV · Δ IV · OI · Volume

class _SmileTable extends StatelessWidget {
  final String prevDate, todayDate;
  final List<_SmileTableRow> rows;

  // Column widths
  static const double _wDte    = 110;
  static const double _wStrike = 64;
  static const double _wIv     = 72;
  static const double _wDelta  = 68;
  static const double _wOi     = 72;
  static const double _wVol    = 68;

  const _SmileTable({
    required this.prevDate, required this.todayDate,
    required this.rows,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: _kBorder),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _header(),
            const Divider(height: 1, thickness: 1, color: _kBorder),
            ...rows.asMap().entries.map((e) => Column(children: [
              if (e.key > 0) const Divider(height: 1, color: Color(0xFF111827)),
              _dataRow(e.value, e.key.isOdd),
            ])),
          ],
        ),
      ),
    );
  }

  Widget _header() => Container(
    color: _kHeaderBg,
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
    child: Row(children: [
      _cell('DTE',         _wDte,    TextAlign.left,  _kMonoHdr),
      _cell('STRIKE',      _wStrike, TextAlign.right, _kMonoHdr),
      _cell(prevDate,      _wIv,     TextAlign.right, _kMonoHdr),
      _cell(todayDate,     _wIv,     TextAlign.right, _kMonoHdr),
      _cell('Δ IV',        _wDelta,  TextAlign.right, _kMonoHdr),
      _cell('OI',          _wOi,     TextAlign.right, _kMonoHdr),
      _cell('VOLUME',      _wVol,    TextAlign.right, _kMonoHdr),
    ]),
  );

  Widget _dataRow(_SmileTableRow r, bool alt) {
    final hl = _deltaHighlight(r.deltaIv);
    return Container(
      color: alt ? _kAltBg : Colors.transparent,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      child: Row(children: [
        _cell(r.dte, _wDte, TextAlign.left, _kMono),
        _cell(
          r.strike != null ? '\$${r.strike!.toStringAsFixed(1)}' : '—',
          _wStrike, TextAlign.right, _kMono,
        ),
        _cell(_fmtIv(r.prevIv),  _wIv, TextAlign.right, _kMono),
        _cell(_fmtIv(r.todayIv), _wIv, TextAlign.right,
            _kMono.copyWith(fontWeight: FontWeight.w600)),
        // Δ cell with optional background highlight
        Container(
          width: _wDelta,
          alignment: Alignment.centerRight,
          decoration: hl != null
              ? BoxDecoration(
                  color: hl,
                  borderRadius: BorderRadius.circular(3),
                )
              : null,
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
          child: Text(
            _fmtIv(r.deltaIv, signed: true),
            style: _kMono.copyWith(
              color:      _deltaTextColor(r.deltaIv),
              fontWeight: FontWeight.w700,
            ),
            textAlign: TextAlign.right,
          ),
        ),
        _cell(r.oi     != null ? _fmtInt(r.oi!)     : '—', _wOi,  TextAlign.right, _kMono),
        _cell(r.volume != null ? _fmtInt(r.volume!)  : '—', _wVol, TextAlign.right, _kMono),
      ]),
    );
  }

  static Widget _cell(String text, double width, TextAlign align, TextStyle style) =>
      SizedBox(width: width, child: Text(text, style: style, textAlign: align, overflow: TextOverflow.ellipsis));
}

// ── Slope table ────────────────────────────────────────────────────────────────
// Columns: DTE · Prev Slope · Today Slope · Δ Slope

class _SlopeTable extends StatelessWidget {
  final String prevDate, todayDate;
  final List<_SkewRow> rows;

  static const double _wDte   = 110;
  static const double _wSlope = 90;
  static const double _wDelta = 80;

  const _SlopeTable({
    required this.prevDate, required this.todayDate,
    required this.rows,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: _kBorder),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _header(),
            const Divider(height: 1, thickness: 1, color: _kBorder),
            ...rows.asMap().entries.map((e) => Column(children: [
              if (e.key > 0) const Divider(height: 1, color: Color(0xFF111827)),
              _dataRow(e.value, e.key.isOdd),
            ])),
          ],
        ),
      ),
    );
  }

  Widget _header() => Container(
    color: _kHeaderBg,
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
    child: Row(children: [
      _cell('DTE',      _wDte,   TextAlign.left,  _kMonoHdr),
      _cell(prevDate,   _wSlope, TextAlign.right, _kMonoHdr),
      _cell(todayDate,  _wSlope, TextAlign.right, _kMonoHdr),
      _cell('Δ SLOPE',  _wDelta, TextAlign.right, _kMonoHdr),
    ]),
  );

  Widget _dataRow(_SkewRow r, bool alt) {
    final hl = _deltaHighlight(r.dSlope);
    return Container(
      color: alt ? _kAltBg : Colors.transparent,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      child: Row(children: [
        _cell(r.label,                            _wDte,   TextAlign.left,  _kMono),
        _cell(_fmtIv(r.prevSlope,  signed: true), _wSlope, TextAlign.right, _kMono),
        _cell(_fmtIv(r.todaySlope, signed: true), _wSlope, TextAlign.right,
            _kMono.copyWith(fontWeight: FontWeight.w600)),
        Container(
          width: _wDelta,
          alignment: Alignment.centerRight,
          decoration: hl != null
              ? BoxDecoration(color: hl, borderRadius: BorderRadius.circular(3))
              : null,
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
          child: Text(
            _fmtIv(r.dSlope, signed: true),
            style: _kMono.copyWith(
                color:      _deltaTextColor(r.dSlope),
                fontWeight: FontWeight.w700),
            textAlign: TextAlign.right,
          ),
        ),
      ]),
    );
  }

  static Widget _cell(String text, double width, TextAlign align, TextStyle style) =>
      SizedBox(width: width, child: Text(text, style: style, textAlign: align, overflow: TextOverflow.ellipsis));
}
