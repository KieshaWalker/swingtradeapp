import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../services/census/census_models.dart';
import '../providers/api_data_providers.dart';
import 'api_tile_widgets.dart';

class CensusTab extends ConsumerWidget {
  const CensusTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final retail = ref.watch(censusRetailSalesProvider);
    final motorVehicles = ref.watch(censusMotorVehiclesProvider);
    final nonStore = ref.watch(censusNonStoreProvider);
    final construction = ref.watch(censusConstructionSpendingProvider);
    final mfgOrders = ref.watch(censusManufacturingOrdersProvider);
    final wholesale = ref.watch(censusWholesaleSalesProvider);

    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(censusRetailSalesProvider);
        ref.invalidate(censusMotorVehiclesProvider);
        ref.invalidate(censusNonStoreProvider);
        ref.invalidate(censusConstructionSpendingProvider);
        ref.invalidate(censusManufacturingOrdersProvider);
        ref.invalidate(censusWholesaleSalesProvider);
      },
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          // ── Retail Trade ─────────────────────────────────────────────────
          const ApiSectionHeader('Retail Trade (MARTS)'),
          ApiTileGrid(children: [
            _CensusTile(
              async: retail,
              label: 'Total Retail Sales',
              sublabel: 'SA, \$M (MARTS 44X72)',
              formatFn: _fmtMrts,
            ),
            _CensusTile(
              async: motorVehicles,
              label: 'Motor Vehicles & Parts',
              sublabel: 'SA, \$M (MARTS 441)',
              formatFn: _fmtMrts,
            ),
            _CensusTile(
              async: nonStore,
              label: 'Non-Store / E-Commerce',
              sublabel: 'SA, \$M (MARTS 454)',
              formatFn: _fmtMrts,
            ),
          ]),
          const SizedBox(height: 20),

          // ── Construction ─────────────────────────────────────────────────
          const ApiSectionHeader('Construction Spending'),
          ApiTileGrid(children: [
            _CensusTile(
              async: construction,
              label: 'Total Construction',
              sublabel: 'Value Put in Place, \$M',
              formatFn: _fmtMrts,
            ),
          ]),
          const SizedBox(height: 20),

          // ── Manufacturing ─────────────────────────────────────────────────
          const ApiSectionHeader('Manufacturing (M3 Survey)'),
          ApiTileGrid(children: [
            _CensusTile(
              async: mfgOrders,
              label: 'Mfg. New Orders',
              sublabel: 'Total, SA, \$M',
              formatFn: _fmtMrts,
            ),
          ]),
          const SizedBox(height: 20),

          // ── Wholesale ────────────────────────────────────────────────────
          const ApiSectionHeader('Wholesale Trade'),
          ApiTileGrid(children: [
            _CensusTile(
              async: wholesale,
              label: 'Wholesale Sales',
              sublabel: 'Monthly, SA, \$M',
              formatFn: _fmtMrts,
            ),
          ]),
        ],
      ),
    );
  }

  static String _fmtMrts(double v) {
    if (v.abs() >= 1000000) return '\$${(v / 1000000).toStringAsFixed(2)}T';
    if (v.abs() >= 1000) return '\$${(v / 1000).toStringAsFixed(1)}B';
    return '\$${v.toStringAsFixed(0)}M';
  }
}

class _CensusTile extends StatelessWidget {
  final AsyncValue<CensusResponse> async;
  final String label;
  final String sublabel;
  final String Function(double)? formatFn;

  const _CensusTile({
    required this.async,
    required this.label,
    required this.sublabel,
    this.formatFn,
  });

  @override
  Widget build(BuildContext context) {
    return async.when(
      loading: () => const ApiTileLoading(),
      error: (_, _) => ApiTilePlaceholder(label: label, sublabel: sublabel),
      data: (resp) {
        final point = censusLatest(resp);
        if (point == null) {
          return ApiTilePlaceholder(label: label, sublabel: sublabel);
        }
        final v = double.tryParse(point.value.replaceAll(',', ''));
        final formatted = v != null && formatFn != null
            ? formatFn!(v)
            : point.value;
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
