import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../services/bea/bea_models.dart';
import '../providers/api_data_providers.dart';
import 'api_tile_widgets.dart';

class BeaTab extends ConsumerWidget {
  const BeaTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final gdp = ref.watch(beaGdpProvider);
    final realGdp = ref.watch(beaRealGdpProvider);
    final pce = ref.watch(beaPceProvider);
    final corePce = ref.watch(beaCorePceProvider);
    final income = ref.watch(beaPersonalIncomeProvider);
    final profits = ref.watch(beaCorporateProfitsProvider);
    final netExports = ref.watch(beaNetExportsProvider);

    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(beaGdpProvider);
        ref.invalidate(beaRealGdpProvider);
        ref.invalidate(beaPceProvider);
        ref.invalidate(beaCorePceProvider);
        ref.invalidate(beaPersonalIncomeProvider);
        ref.invalidate(beaCorporateProfitsProvider);
        ref.invalidate(beaNetExportsProvider);
      },
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          // ── GDP ──────────────────────────────────────────────────────────
          const ApiSectionHeader('Gross Domestic Product'),
          ApiTileGrid(children: [
            _BeaTile(
              async: gdp,
              label: 'GDP % Change',
              sublabel: 'Q/Q SAAR (T10101)',
              suffix: '%',
            ),
            _BeaTile(
              async: realGdp,
              label: 'Real GDP',
              sublabel: 'Chained 2017 \$ (T10106)',
              formatFn: _fmtBillions,
            ),
          ]),
          const SizedBox(height: 20),

          // ── Personal Consumption & Prices ─────────────────────────────────
          const ApiSectionHeader('Personal Consumption & Prices'),
          ApiTileGrid(children: [
            _BeaTile(
              async: pce,
              label: 'PCE % Change',
              sublabel: 'Personal Consumption (T10101)',
              suffix: '%',
            ),
            _BeaTile(
              async: corePce,
              label: 'Core PCE Price Index',
              sublabel: 'Less Food & Energy (T20804)',
            ),
          ]),
          const SizedBox(height: 20),

          // ── Income & Saving ───────────────────────────────────────────────
          const ApiSectionHeader('Personal Income'),
          ApiTileGrid(children: [
            _BeaTile(
              async: income,
              label: 'Personal Income',
              sublabel: 'Billions SAAR (T20100)',
              formatFn: _fmtBillions,
            ),
          ]),
          const SizedBox(height: 20),

          // ── Corporate Profits ─────────────────────────────────────────────
          const ApiSectionHeader('Corporate Profits'),
          ApiTileGrid(children: [
            _BeaTile(
              async: profits,
              label: 'Corp. Profits After Tax',
              sublabel: 'Billions \$ (T10901)',
              formatFn: _fmtBillions,
            ),
          ]),
          const SizedBox(height: 20),

          // ── Trade ─────────────────────────────────────────────────────────
          const ApiSectionHeader('International Trade'),
          ApiTileGrid(children: [
            _BeaTile(
              async: netExports,
              label: 'Net Exports % Change',
              sublabel: 'Goods & Services (T10101)',
              suffix: '%',
            ),
          ]),
        ],
      ),
    );
  }

  static String _fmtBillions(double v) {
    if (v.abs() >= 1000) return '\$${(v / 1000).toStringAsFixed(1)}T';
    return '\$${v.toStringAsFixed(0)}B';
  }
}

class _BeaTile extends StatelessWidget {
  final AsyncValue<BeaResponse> async;
  final String label;
  final String sublabel;
  final String suffix;
  final String Function(double)? formatFn;

  const _BeaTile({
    required this.async,
    required this.label,
    required this.sublabel,
    this.suffix = '',
    this.formatFn,
  });

  @override
  Widget build(BuildContext context) {
    return async.when(
      loading: () => const ApiTileLoading(),
      error: (_, _) => ApiTilePlaceholder(label: label, sublabel: sublabel),
      data: (resp) {
        final point = beaLatest(resp);
        if (point == null) {
          return ApiTilePlaceholder(label: label, sublabel: sublabel);
        }
        final v = double.tryParse(point.value.replaceAll(',', ''));
        final formatted = v != null && formatFn != null
            ? formatFn!(v)
            : '${point.value}$suffix';
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
