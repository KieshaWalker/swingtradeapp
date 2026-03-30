// Shared tile components for the BLS / BEA / EIA / Census dashboard tabs.
// Mirrors the style from economy_pulse_screen.dart but exported for reuse.
import 'package:flutter/material.dart';
import '../../../core/theme.dart';
import '../../../services/bls/bls_models.dart';
import '../../../services/bea/bea_models.dart';
import '../../../services/eia/eia_models.dart';
import '../../../services/census/census_models.dart';

// ── Section header ─────────────────────────────────────────────────────────────

class ApiSectionHeader extends StatelessWidget {
  final String title;
  const ApiSectionHeader(this.title, {super.key});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(
          title.toUpperCase(),
          style: const TextStyle(
            color: AppTheme.neutralColor,
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.2,
          ),
        ),
      );
}

// ── 2-column grid ─────────────────────────────────────────────────────────────

class ApiTileGrid extends StatelessWidget {
  final List<Widget> children;
  const ApiTileGrid({super.key, required this.children});

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i += 2) {
      final hasSecond = i + 1 < children.length;
      rows.add(Row(children: [
        Expanded(child: children[i]),
        const SizedBox(width: 8),
        Expanded(child: hasSecond ? children[i + 1] : const SizedBox()),
      ]));
      if (i + 2 < children.length) rows.add(const SizedBox(height: 8));
    }
    return Column(children: rows);
  }
}

// ── Base tile ──────────────────────────────────────────────────────────────────

class ApiTile extends StatelessWidget {
  final String label;
  final String sublabel;
  final String value;
  final String? date;
  final Color? valueColor;

  const ApiTile({
    super.key,
    required this.label,
    required this.sublabel,
    required this.value,
    this.date,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppTheme.cardColor,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppTheme.borderColor),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.white),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
            Text(sublabel,
                style: const TextStyle(
                    color: AppTheme.neutralColor, fontSize: 10),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
            const SizedBox(height: 6),
            Text(value,
                style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.5,
                    color: valueColor ?? Colors.white)),
            if (date != null)
              Text(date!,
                  style: const TextStyle(
                      color: AppTheme.neutralColor, fontSize: 11)),
          ],
        ),
      );
}

// ── Loading / error placeholder ────────────────────────────────────────────────

class ApiTilePlaceholder extends StatelessWidget {
  final String label;
  final String sublabel;
  const ApiTilePlaceholder(
      {super.key, required this.label, required this.sublabel});

  @override
  Widget build(BuildContext context) => ApiTile(
        label: label,
        sublabel: sublabel,
        value: '—',
        date: 'No data',
        valueColor: AppTheme.neutralColor,
      );
}

class ApiTileLoading extends StatelessWidget {
  const ApiTileLoading({super.key});

  @override
  Widget build(BuildContext context) => Container(
        height: 88,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppTheme.cardColor,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppTheme.borderColor),
        ),
        child: const Center(
          child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      );
}

// ── Helpers ────────────────────────────────────────────────────────────────────

/// Returns the latest non-null, non-dash value from a BLS series by seriesId.
({String value, String date})? blsLatest(BlsResponse resp, String seriesId) {
  final series = resp.series.where((s) => s.seriesId == seriesId).firstOrNull;
  if (series == null) return null;
  for (final d in series.data) {
    if (d.value != 0.0 || d.year.isNotEmpty) {
      // Filter out dash values (stored as 0.0 but originally "-")
      final raw = series.data
          .where((x) => x.year.isNotEmpty)
          .firstOrNull;
      if (raw == null) return null;
      return (value: raw.value.toString(), date: '${raw.periodName} ${raw.year}');
    }
  }
  return null;
}

/// Returns the latest non-null value from a BEA response.
({String value, String date})? beaLatest(BeaResponse resp) {
  if (resp.data.isEmpty) return null;
  final obs = resp.data.first;
  return (value: obs.dataValue, date: obs.timePeriod);
}

/// Returns the latest value from an EIA response.
({String value, String date})? eiaLatest(EiaResponse resp) {
  if (resp.data.isEmpty) return null;
  final d = resp.data.first;
  return (value: d.value?.toStringAsFixed(1) ?? '—', date: d.period);
}

/// Returns the most recent cell_value from a Census MARTS response.
({String value, String date})? censusLatest(CensusResponse resp) {
  if (resp.rows.isEmpty) return null;
  // Rows are ascending by time; take the last row with a numeric value
  final rows = resp.toRetailRows().reversed.toList();
  for (final r in rows) {
    if (r.value != null) {
      return (value: r.cellValue, date: r.period);
    }
  }
  return null;
}

String fmtMillions(String raw) {
  final v = double.tryParse(raw.replaceAll(',', ''));
  if (v == null) return raw;
  if (v.abs() >= 1000000) return '\$${(v / 1000000).toStringAsFixed(1)}T';
  if (v.abs() >= 1000) return '\$${(v / 1000).toStringAsFixed(1)}B';
  return '\$${v.toStringAsFixed(0)}M';
}
