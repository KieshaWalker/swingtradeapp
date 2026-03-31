import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../services/eia/eia_models.dart';
import '../providers/api_data_providers.dart';
import 'api_tile_widgets.dart';
import 'gasoline_price_history_chart.dart';
import 'nat_gas_import_chart.dart';

class EiaTab extends ConsumerWidget {
  const EiaTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final gasPrices = ref.watch(eiaGasolinePricesProvider);
    final crudeStocks = ref.watch(eiaCrudeStocksProvider);
    final crudeProd = ref.watch(eiaCrudeProdProvider);
    final natGas = ref.watch(eiaNatGasStorageProvider);
    final refinery = ref.watch(eiaRefineryUtilProvider);
    final spr = ref.watch(eiaSprProvider);

    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(eiaGasolinePricesProvider);
        ref.invalidate(eiaGasolinePriceHistoryProvider);
        ref.invalidate(eiaCrudeStocksProvider);
        ref.invalidate(eiaCrudeProdProvider);
        ref.invalidate(eiaNatGasStorageProvider);
        ref.invalidate(eiaRefineryUtilProvider);
        ref.invalidate(eiaSprProvider);
      },
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          // ── Petroleum ────────────────────────────────────────────────────
          const ApiSectionHeader('Petroleum (Weekly)'),
          ApiTileGrid(children: [
            _EiaTile(
              async: gasPrices,
              label: 'Retail Gasoline Price',
              sublabel: 'US Average (\$/gal)',
              prefix: '\$',
            ),
            _EiaTile(
              async: crudeStocks,
              label: 'Crude Oil Stocks',
              sublabel: 'Commercial (Thousand Bbl)',
              formatFn: _fmtThousandBbl,
            ),
            _EiaTile(
              async: crudeProd,
              label: 'Crude Oil Production',
              sublabel: 'US Weekly (Mb/d)',
            ),
            _EiaTile(
              async: refinery,
              label: 'Refinery Utilization',
              sublabel: '% of Operable Capacity',
              suffix: '%',
            ),
            _EiaTile(
              async: spr,
              label: 'Strategic Petroleum Reserve',
              sublabel: 'Thousand Barrels',
              formatFn: _fmtThousandBbl,
            ),
          ]),
          const SizedBox(height: 16),

          // ── Gasoline Price History ────────────────────────────────────────
          const ApiSectionHeader('Gasoline Price History'),
          const SizedBox(height: 8),
          const GasolinePriceHistoryChart(),
          const SizedBox(height: 20),

          // ── Natural Gas ──────────────────────────────────────────────────
          const ApiSectionHeader('Natural Gas (Weekly)'),
          ApiTileGrid(children: [
            _EiaTile(
              async: natGas,
              label: 'Nat. Gas Storage',
              sublabel: 'Working Gas (Bcf)',
              formatFn: _fmtBcf,
            ),
          ]),
          const SizedBox(height: 16),

          // ── Import Price History ──────────────────────────────────────────
          const ApiSectionHeader('Natural Gas Import Price History'),
          const SizedBox(height: 8),
          const NatGasImportChart(),
        ],
      ),
    );
  }

  static String _fmtThousandBbl(double v) {
    if (v >= 1000000) return '${(v / 1000000).toStringAsFixed(1)}B bbl';
    if (v >= 1000) return '${(v / 1000).toStringAsFixed(1)}M bbl';
    return '${v.toStringAsFixed(0)}K bbl';
  }

  static String _fmtBcf(double v) => '${v.toStringAsFixed(0)} Bcf';
}

class _EiaTile extends StatelessWidget {
  final AsyncValue<EiaResponse> async;
  final String label;
  final String sublabel;
  final String prefix;
  final String suffix;
  final String Function(double)? formatFn;

  const _EiaTile({
    required this.async,
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
        final point = eiaLatest(resp);
        if (point == null) {
          return ApiTilePlaceholder(label: label, sublabel: sublabel);
        }
        final v = double.tryParse(point.value);
        final formatted = v != null && formatFn != null
            ? formatFn!(v)
            : '$prefix${point.value}$suffix';
        return ApiTile(
          label: label,
          sublabel: sublabel,
          value: formatted,
          date: point.date,
        );
      },
    );
  }
}
