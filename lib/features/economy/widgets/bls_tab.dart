import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../services/bls/bls_models.dart';
import '../providers/api_data_providers.dart';
import 'api_tile_widgets.dart';

class BlsTab extends ConsumerWidget {
  const BlsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final employment = ref.watch(blsEmploymentProvider);
    final cpi = ref.watch(blsCpiProvider);
    final ppi = ref.watch(blsPpiProvider);
    final jolts = ref.watch(blsJoltsProvider);

    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(blsEmploymentProvider);
        ref.invalidate(blsCpiProvider);
        ref.invalidate(blsPpiProvider);
        ref.invalidate(blsJoltsProvider);
      },
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          // ── Employment Situation ─────────────────────────────────────────
          const ApiSectionHeader('Employment Situation'),
          ApiTileGrid(children: [
            _BlsTile(
              async: employment,
              seriesId: BlsSeriesIds.unemploymentRateU3,
              label: 'Unemployment U-3',
              sublabel: 'CPS',
              suffix: '%',
            ),
            _BlsTile(
              async: employment,
              seriesId: BlsSeriesIds.unemploymentRateU6,
              label: 'Unemployment U-6',
              sublabel: 'Underemployment',
              suffix: '%',
            ),
            _BlsTile(
              async: employment,
              seriesId: BlsSeriesIds.totalNonfarmPayrolls,
              label: 'Nonfarm Payrolls',
              sublabel: 'CES (thousands)',
              formatFn: _fmtPayrolls,
            ),
            _BlsTile(
              async: employment,
              seriesId: BlsSeriesIds.laborForceParticipationRate,
              label: 'Labor Force Participation',
              sublabel: 'CPS',
              suffix: '%',
            ),
            _BlsTile(
              async: employment,
              seriesId: BlsSeriesIds.avgHourlyEarningsPrivate,
              label: 'Avg Hourly Earnings',
              sublabel: 'All Private',
              prefix: '\$',
            ),
            _BlsTile(
              async: employment,
              seriesId: BlsSeriesIds.avgWeeklyHoursPrivate,
              label: 'Avg Weekly Hours',
              sublabel: 'All Private',
              suffix: ' hrs',
            ),
          ]),
          const SizedBox(height: 20),

          // ── Consumer Prices ──────────────────────────────────────────────
          const ApiSectionHeader('Consumer Price Index'),
          ApiTileGrid(children: [
            _BlsTile(
              async: cpi,
              seriesId: BlsSeriesIds.cpiAllItemsSA,
              label: 'CPI All Items (SA)',
              sublabel: 'Index, 1982-84=100',
            ),
            _BlsTile(
              async: cpi,
              seriesId: BlsSeriesIds.cpiCore,
              label: 'Core CPI',
              sublabel: 'Less Food & Energy',
            ),
            _BlsTile(
              async: cpi,
              seriesId: BlsSeriesIds.cpiShelter,
              label: 'CPI Shelter',
              sublabel: 'Housing Component',
            ),
            _BlsTile(
              async: cpi,
              seriesId: BlsSeriesIds.cpiFood,
              label: 'CPI Food',
              sublabel: 'Food at Home + Away',
            ),
            _BlsTile(
              async: cpi,
              seriesId: BlsSeriesIds.cpiEnergy,
              label: 'CPI Energy',
              sublabel: 'Energy Component',
            ),
          ]),
          const SizedBox(height: 20),

          // ── Producer Prices ──────────────────────────────────────────────
          const ApiSectionHeader('Producer Price Index'),
          ApiTileGrid(children: [
            _BlsTile(
              async: ppi,
              seriesId: BlsSeriesIds.ppiFinalDemand,
              label: 'PPI Final Demand',
              sublabel: 'Index, Nov 2009=100',
            ),
            _BlsTile(
              async: ppi,
              seriesId: BlsSeriesIds.ppiFinalDemandLessFoodEnergy,
              label: 'Core PPI',
              sublabel: 'Less Food & Energy',
            ),
            _BlsTile(
              async: ppi,
              seriesId: BlsSeriesIds.ppiFinalDemandGoods,
              label: 'PPI Goods',
              sublabel: 'Final Demand Goods',
            ),
            _BlsTile(
              async: ppi,
              seriesId: BlsSeriesIds.ppiFinalDemandServices,
              label: 'PPI Services',
              sublabel: 'Final Demand Services',
            ),
          ]),
          const SizedBox(height: 20),

          // ── JOLTS ────────────────────────────────────────────────────────
          const ApiSectionHeader('Job Openings & Labor Turnover'),
          ApiTileGrid(children: [
            _BlsTile(
              async: jolts,
              seriesId: BlsSeriesIds.jobOpenings,
              label: 'Job Openings',
              sublabel: 'Total (thousands)',
              formatFn: _fmtPayrolls,
            ),
            _BlsTile(
              async: jolts,
              seriesId: BlsSeriesIds.hires,
              label: 'Hires',
              sublabel: 'Total (thousands)',
              formatFn: _fmtPayrolls,
            ),
            _BlsTile(
              async: jolts,
              seriesId: BlsSeriesIds.quits,
              label: 'Quits',
              sublabel: 'Total (thousands)',
              formatFn: _fmtPayrolls,
            ),
            _BlsTile(
              async: jolts,
              seriesId: BlsSeriesIds.layoffsDischarges,
              label: 'Layoffs & Discharges',
              sublabel: 'Total (thousands)',
              formatFn: _fmtPayrolls,
            ),
            _BlsTile(
              async: jolts,
              seriesId: BlsSeriesIds.jobOpeningsRate,
              label: 'Job Openings Rate',
              sublabel: '% of Employment',
              suffix: '%',
            ),
            _BlsTile(
              async: jolts,
              seriesId: BlsSeriesIds.quitsRate,
              label: 'Quits Rate',
              sublabel: '% of Employment',
              suffix: '%',
            ),
          ]),
        ],
      ),
    );
  }

  static String _fmtPayrolls(double v) {
    if (v.abs() >= 1000) return '${(v / 1000).toStringAsFixed(1)}M';
    return '${v.toStringAsFixed(0)}K';
  }
}

class _BlsTile extends StatelessWidget {
  final AsyncValue<BlsResponse> async;
  final String seriesId;
  final String label;
  final String sublabel;
  final String prefix;
  final String suffix;
  final String Function(double)? formatFn;

  const _BlsTile({
    required this.async,
    required this.seriesId,
    required this.label,
    required this.sublabel,
    this.prefix = '',
    this.suffix = '',
    this.formatFn,
  });

  @override
  Widget build(BuildContext context) {
    return async.when(
      loading: () => const ApiTileLoading(),
      error: (_, _) => ApiTilePlaceholder(label: label, sublabel: sublabel),
      data: (resp) {
        final series = resp.series
            .where((s) => s.seriesId == seriesId)
            .firstOrNull;
        final point = _firstValid(series);
        if (point == null) {
          return ApiTilePlaceholder(label: label, sublabel: sublabel);
        }
        final formatted = formatFn != null
            ? formatFn!(point.value)
            : '$prefix${point.value.toStringAsFixed(1)}$suffix';
        return ApiTile(
          label: label,
          sublabel: sublabel,
          value: formatted,
          date: '${point.periodName} ${point.year}',
        );
      },
    );
  }

  BlsDataPoint? _firstValid(BlsSeries? series) {
    if (series == null) return null;
    for (final d in series.data) {
      // BLS marks unavailable data as "-" which parses to 0 — skip those
      // by checking the raw response footnotes via a non-zero heuristic.
      // A better check would store the raw string, but value > 0 works for
      // rates, levels, earnings.
      if (d.value > 0) return d;
    }
    return series.data.firstOrNull;
  }
}
