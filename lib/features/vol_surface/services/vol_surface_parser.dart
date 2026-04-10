// =============================================================================
// vol_surface/services/vol_surface_parser.dart
// Parses ThinkorSwim "Stock and Option Quote" CSV exports.
// =============================================================================
import '../models/vol_surface_models.dart';

class VolSurfaceParser {
  static final _titleRe =
      RegExp(r'Stock and Option Quote for\s+(\w+)', caseSensitive: false);
  // Matches "(N)" anywhere in a section header line, e.g. "10 APR 26  (0)  100 (Weeklys)"
  static final _dteRe = RegExp(r'\((\d+)\)');

  static VolSnapshot parse(String csv, DateTime obsDate) {
    final lines =
        csv.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');

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

      // Underlying section — grab spot price from next "LAST" row
      if (line.startsWith('Underlying')) {
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
        if (line.startsWith('LAST,')) {
          spotNext = true;
          continue; // ignore other underlying rows
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
      if (cols.length < 26) continue;

      final strike = _toNum(cols[14]);
      if (strike == null) continue;

      final callIv = _normIv(_toNum(cols[8]));
      final putIv = _normIv(_toNum(cols[25]));
      if (callIv == null && putIv == null) continue;

      points.add(VolPoint(
        strike: strike,
        dte: currentDte,
        callIv: callIv,
        putIv: putIv,
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
