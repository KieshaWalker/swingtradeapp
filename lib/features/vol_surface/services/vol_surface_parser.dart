// =============================================================================
// vol_surface/services/vol_surface_parser.dart
// Parses ThinkorSwim "Stock and Option Quote" CSV exports.
// =============================================================================
import '../models/vol_surface_models.dart';

class VolSurfaceParser {
  // Matches both known ThinkorSwim title formats:
  //   "Stock and Option Quote for AMZN"
  //   "Stock quote and option quote for AMZN on 4/10/26 07:31:41"
  static final _titleRe =
      RegExp(r'stock.*?quote.*?\bfor\b\s+([A-Z0-9.]+)', caseSensitive: false);
  // Matches "(N)" anywhere in a section header line, e.g. "10 APR 26  (0)  100 (Weeklys)"
  static final _dteRe = RegExp(r'\((\d+)\)');

  static VolSnapshot parse(String csv, DateTime obsDate) {
    final lines = csv
        .replaceAll('\u{FEFF}', '') // strip UTF-8 BOM
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n');

    String ticker = '';
    double? spotPrice;
    int? currentDte;
    bool inUnderlying = false;
    bool spotNext = false;
    final points = <VolPoint>[];

    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;

      // Title row
      final titleMatch = _titleRe.firstMatch(line);
      if (titleMatch != null) {
        ticker = titleMatch.group(1)!;
        continue;
      }

      // Underlying section — exact match only ("UNDERLYING EXTRA INFO" must not trigger)
      if (line.toUpperCase() == 'UNDERLYING') {
        inUnderlying = true;
        continue;
      }
      if (inUnderlying) {
        if (spotNext) {
          final cols = _splitLine(line);
          spotPrice = _toNum(cols.isNotEmpty ? cols[0] : '');
          spotNext = false;
          inUnderlying = false;
          continue;
        }
        // "LAST,LX,..." header row precedes the spot price row
        if (line.startsWith('LAST,')) {
          spotNext = true;
          continue;
        }
        continue;
      }

      // Section header line — contains "(DTE)" — but skip CALLS/PUTS/header rows
      if (!line.startsWith('CALLS') &&
          !line.startsWith('PUTS') &&
          !line.startsWith('Bid,') &&
          !line.startsWith('Delta,') &&
          !line.startsWith('Prob')) {
        final m = _dteRe.firstMatch(line);
        if (m != null) {
          currentDte = int.parse(m.group(1)!);
          continue;
        }
      }

      if (currentDte == null) continue;
      if (line.startsWith('CALLS') ||
          line.startsWith('PUTS') ||
          line.startsWith('Bid,') ||
          line.startsWith('Delta,') ||
          line.startsWith('Prob')) {
        continue;
      }

      final cols = _splitLine(line);
      if (cols.length < 35) continue;

      // Confirmed ThinkorSwim "Stock and Option Quote" column layout:
      // [0,1] empty  [2] CallVol  [3] CallOI  [4] ProbOTM  [5] ProbITM
      // [6] Size  [7] Delta  [8] ImplVol(call)  [9] Gamma  [10] Rho
      // [11] Theta  [12] Vega  [13] Extrinsic  [14] Intrinsic
      // [15] High  [16] Low  [17] TheoPrice  [18] BID  [19] BX  [20] ASK
      // [21] AX  [22] Exp  [23] Strike
      // [24] BID(put)  [25] BX  [26] ASK  [27] AX  [28] PutVol  [29] PutOI
      // [30] ProbOTM  [31] ProbITM  [32] Size  [33] Delta  [34] ImplVol(put)
      // [35..43] Gamma Rho Theta Vega Extrinsic Intrinsic High Low TheoPrice
      final strike = _toNum(cols[23]);
      if (strike == null) continue;

      final callIv = _normIv(_toNum(cols[8]));
      final putIv = _normIv(_toNum(cols[34]));
      if (callIv == null && putIv == null) continue;

      // Volume and Open Interest
      final callVolume = _toInt(cols[2]);
      final callOI     = _toInt(cols[3]);
      final putVolume  = _toInt(cols[28]);
      final putOI      = _toInt(cols[29]);

      points.add(VolPoint(
        strike: strike,
        dte: currentDte,
        callIv: callIv,
        putIv: putIv,
        callVolume: callVolume,
        putVolume: putVolume,
        callOI: callOI,
        putOI: putOI,
      ));
    }

    if (points.isEmpty) {
      throw Exception(
          'No option rows found.\n\nMake sure this is a ThinkorSwim "Stock and Option Quote" export.');
    }

    return VolSnapshot(
      ticker: ticker.isEmpty ? 'UNKNOWN' : ticker,
      obsDate: obsDate,
      spotPrice: spotPrice,
      points: points,
      parsedAt: DateTime.now().toUtc(),
    );
  }

  static List<String> _splitLine(String line) {
    final cols = <String>[];
    bool inQuote = false;
    final cur = StringBuffer();
    for (final ch in line.runes) {
      final c = String.fromCharCode(ch);
      if (c == '"') {
        inQuote = !inQuote;
      } else if (c == ',' && !inQuote) {
        cols.add(cur.toString().trim());
        cur.clear();
      } else {
        cur.write(c);
      }
    }
    cols.add(cur.toString().trim());
    return cols;
  }

  static int? _toInt(String? s) {
    final n = _toNum(s);
    if (n == null) return null;
    final i = n.toInt();
    return i > 0 ? i : null;
  }

  static double? _toNum(String? s) {
    if (s == null || s.isEmpty) return null;
    final cleaned = s.replaceAll(RegExp(r'[,%\s]'), '');
    if (cleaned.isEmpty) return null;
    final n = double.tryParse(cleaned);
    return (n == null || n.isNaN || n.isInfinite) ? null : n;
  }

  static double? _normIv(double? v) {
    if (v == null) return null;
    // ThinkorSwim exports IV as a percent (e.g. 45.3), normalise to decimal
    return v > 1 ? v / 100 : v;
  }
}
