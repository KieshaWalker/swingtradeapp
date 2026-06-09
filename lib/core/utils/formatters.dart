// =============================================================================
// core/utils/formatters.dart
// =============================================================================
// Shared display formatters for dollar values, share counts and dates.
// Replaces the per-widget _fmtVal / _fmtShares / month-abbreviation copies
// scattered across the feature screens.
// =============================================================================

/// 1-indexed month abbreviations — kMonthAbbr[d.month].
const kMonthAbbr = [
  '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// '$1.2B' / '$3.4M' / '$560K' / '$87' — `decimals` applies to the B/M tiers,
/// `kDecimals` to the K tier. Negatives keep the sign outside the '$'
/// ('-$1.5K'); `sign: true` prefixes '+' on positives.
String fmtCompactDollars(double v,
    {int decimals = 1, int kDecimals = 0, bool sign = false}) {
  final prefix = v < 0 ? '-' : (sign ? '+' : '');
  final a = v.abs();
  final String core;
  if (a >= 1e9) {
    core = '\$${(a / 1e9).toStringAsFixed(decimals)}B';
  } else if (a >= 1e6) {
    core = '\$${(a / 1e6).toStringAsFixed(decimals)}M';
  } else if (a >= 1e3) {
    core = '\$${(a / 1e3).toStringAsFixed(kDecimals)}K';
  } else {
    core = '\$${a.toStringAsFixed(0)}';
  }
  return '$prefix$core';
}

/// '1.2M' / '450K' / '87' — compact share / contract counts.
String fmtCompactCount(num v) {
  if (v >= 1e6) return '${(v / 1e6).toStringAsFixed(1)}M';
  if (v >= 1e3) return '${(v / 1e3).toStringAsFixed(0)}K';
  return v.toStringAsFixed(0);
}

/// '12,345' — integer with thousands separators.
String fmtThousands(int v) => v.toString().replaceAllMapped(
    RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (m) => '${m[1]},');

/// 'Jan 5, 2026'.
String fmtMediumDate(DateTime d) => '${kMonthAbbr[d.month]} ${d.day}, ${d.year}';
