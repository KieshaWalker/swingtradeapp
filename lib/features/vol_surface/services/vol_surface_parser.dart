// =============================================================================
// vol_surface/services/vol_surface_parser.dart
// Parses ThinkorSwim "Stock and Option Quote" CSV exports,
// and converts live Schwab options chains into VolSnapshot format.
// =============================================================================
import '../../../services/schwab/schwab_models.dart';
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

  // ── Live chain ingestion ───────────────────────────────────────────────────
  // Converts a Schwab options chain into a VolSnapshot using the same
  // VolPoint schema as the TOS CSV path. Calls and puts are in separate
  // lists per expiration so we merge them by (strike, dte) key.
  // Schwab's impliedVolatility is in percent (e.g. 45.3) — same as TOS.

  static VolSnapshot fromChain(SchwabOptionsChain chain) {
    // key: "${strike}_${dte}"  →  accumulate call & put sides separately
    final callSide = <String, SchwabOptionContract>{};
    final putSide  = <String, SchwabOptionContract>{};

    for (final exp in chain.expirations) {
      for (final c in exp.calls) {
        if (c.impliedVolatility > 0) {
          callSide['${c.strikePrice}_${exp.dte}'] = c;
        }
      }
      for (final p in exp.puts) {
        if (p.impliedVolatility > 0) {
          putSide['${p.strikePrice}_${exp.dte}'] = p;
        }
      }
    }

    final allKeys = {...callSide.keys, ...putSide.keys};
    final points  = <VolPoint>[];

    for (final key in allKeys) {
      final parts  = key.split('_');
      final strike = double.parse(parts[0]);
      final dte    = int.parse(parts[1]);
      final c      = callSide[key];   // call contract (nullable)
      final p      = putSide[key];    // put  contract (nullable)

      // Prob ITM ≈ |delta| (N(d1) proxy for N(d2); close enough for display)
      final callProbItm = c != null && c.delta > 0 ? c.delta.clamp(0.0, 1.0) : null;
      final putProbItm  = p != null && p.delta < 0 ? p.delta.abs().clamp(0.0, 1.0) : null;

      points.add(VolPoint(
        strike: strike,
        dte:    dte,
        // IV (% → decimal)
        callIv: c != null && c.impliedVolatility > 0 ? c.impliedVolatility / 100 : null,
        putIv:  p != null && p.impliedVolatility > 0 ? p.impliedVolatility / 100 : null,
        // Volume / OI
        callVolume: c != null && c.totalVolume  > 0 ? c.totalVolume  : null,
        putVolume:  p != null && p.totalVolume   > 0 ? p.totalVolume  : null,
        callOI:     c != null && c.openInterest > 0  ? c.openInterest : null,
        putOI:      p != null && p.openInterest > 0  ? p.openInterest : null,
        // Greeks
        callDelta: c?.delta,
        putDelta:  p?.delta,
        callGamma: c != null && c.gamma != 0 ? c.gamma : null,
        putGamma:  p != null && p.gamma != 0 ? p.gamma : null,
        callTheta: c != null && c.theta != 0 ? c.theta : null,
        putTheta:  p != null && p.theta != 0 ? p.theta : null,
        callVega:  c != null && c.vega  != 0 ? c.vega  : null,
        putVega:   p != null && p.vega  != 0 ? p.vega  : null,
        callRho:   c != null && c.rho   != 0 ? c.rho   : null,
        putRho:    p != null && p.rho   != 0 ? p.rho   : null,
        // Pricing
        callBid:       c != null && c.bid  > 0 ? c.bid  : null,
        callAsk:       c != null && c.ask  > 0 ? c.ask  : null,
        callMark:      c != null && c.markPrice > 0 ? c.markPrice : null,
        callLast:      c != null && c.last > 0 ? c.last : null,
        callTheo:      c != null && c.theoreticalOptionValue > 0 ? c.theoreticalOptionValue : null,
        callIntrinsic: c != null && c.intrinsicValue > 0 ? c.intrinsicValue : null,
        callExtrinsic: c != null && c.timeValue      > 0 ? c.timeValue      : null,
        callHigh:      c != null && c.highPrice > 0 ? c.highPrice : null,
        callLow:       c != null && c.lowPrice  > 0 ? c.lowPrice  : null,
        putBid:        p != null && p.bid  > 0 ? p.bid  : null,
        putAsk:        p != null && p.ask  > 0 ? p.ask  : null,
        putMark:       p != null && p.markPrice > 0 ? p.markPrice : null,
        putLast:       p != null && p.last > 0 ? p.last : null,
        putTheo:       p != null && p.theoreticalOptionValue > 0 ? p.theoreticalOptionValue : null,
        putIntrinsic:  p != null && p.intrinsicValue > 0 ? p.intrinsicValue : null,
        putExtrinsic:  p != null && p.timeValue      > 0 ? p.timeValue      : null,
        putHigh:       p != null && p.highPrice > 0 ? p.highPrice : null,
        putLow:        p != null && p.lowPrice  > 0 ? p.lowPrice  : null,
        // Size
        callBidSize: c != null && c.bidSize > 0 ? c.bidSize : null,
        callAskSize: c != null && c.askSize > 0 ? c.askSize : null,
        putBidSize:  p != null && p.bidSize > 0 ? p.bidSize : null,
        putAskSize:  p != null && p.askSize > 0 ? p.askSize : null,
        // Probabilities
        callProbItm: callProbItm,
        callProbOtm: callProbItm != null ? 1.0 - callProbItm : null,
        putProbItm:  putProbItm,
        putProbOtm:  putProbItm  != null ? 1.0 - putProbItm  : null,
      ));
    }

    // Sort by DTE then strike for consistent ordering
    points.sort((a, b) {
      final d = a.dte.compareTo(b.dte);
      return d != 0 ? d : a.strike.compareTo(b.strike);
    });

    final now   = DateTime.now().toUtc();
    final today = DateTime.utc(now.year, now.month, now.day);

    return VolSnapshot(
      ticker:    chain.symbol,
      obsDate:   today,
      spotPrice: chain.underlyingPrice,
      points:    points,
      parsedAt:  now,
    );
  }
}
