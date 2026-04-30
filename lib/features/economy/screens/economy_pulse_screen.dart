// =============================================================================
// features/economy/screens/economy_pulse_screen.dart — Economy Pulse tab
// =============================================================================
// Two-tab screen:
//   Snapshot — real-time macroeconomic dashboard sourced from Schwab + gov APIs
//   Charts   — day-by-day / monthly historical charts from Supabase
//
// Each time the Snapshot data loads the latest values are upserted into the
// three Supabase economy snapshot tables so charts accumulate over time.
//
// Storage:  EconomyStorageService via economyStorageServiceProvider
// =============================================================================
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../core/theme.dart';
import '../../../core/widgets/app_menu_button.dart';
import '../../../services/economy/economy_storage_providers.dart';
import '../../../services/schwab/schwab_models.dart';
import '../../../services/economy/economy_snapshot_models.dart';
import '../../../services/economy/economy_storage_service.dart';
import '../../../features/economy/providers/api_data_providers.dart';
import '../../../services/fred/fred_models.dart';
import '../../../services/fred/fred_providers.dart';
import '../../../services/bls/bls_models.dart';
import '../../../services/bea/bea_models.dart';
import '../../../services/eia/eia_models.dart';
import '../../../services/census/census_models.dart';
import '../../../services/schwab/schwab_providers.dart';
import '../widgets/economy_charts_tab.dart';
import '../widgets/bls_tab.dart';
import '../widgets/bea_tab.dart';
import '../widgets/eia_tab.dart';
import '../widgets/census_tab.dart';
import '../widgets/fred_tab.dart';
import '../widgets/kalshi_tab.dart';
import '../../../services/kalshi/kalshi_providers.dart';

class EconomyPulseScreen extends ConsumerWidget {
  const EconomyPulseScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pulseAsync = ref.watch(economyPulseProvider);

    final storage = ref.read(economyStorageServiceProvider);

    // ── Snapshot (Schwab quotes + gov indicators) — persist on each fetch
    ref.listen<AsyncValue<EconomyPulseData>>(economyPulseProvider, (_, next) {
      next.whenData((data) => storage.saveEconomyPulse(data));
    });

    // ── BLS — persist all series responses ───────────────────────────────────
    ref.listen<AsyncValue<BlsResponse>>(
      blsEmploymentProvider,
      (_, next) => next.whenData(storage.saveBlsResponse),
    );
    ref.listen<AsyncValue<BlsResponse>>(
      blsCpiProvider,
      (_, next) => next.whenData(storage.saveBlsResponse),
    );
    ref.listen<AsyncValue<BlsResponse>>(
      blsPpiProvider,
      (_, next) => next.whenData(storage.saveBlsResponse),
    );
    ref.listen<AsyncValue<BlsResponse>>(
      blsJoltsProvider,
      (_, next) => next.whenData(storage.saveBlsResponse),
    );

    // ── BEA — persist each named series ──────────────────────────────────────
    ref.listen<AsyncValue<BeaResponse>>(
      beaGdpProvider,
      (_, next) =>
          next.whenData((d) => storage.saveBeaResponse(d, EconIds.beaGdpPct)),
    );
    ref.listen<AsyncValue<BeaResponse>>(
      beaRealGdpProvider,
      (_, next) =>
          next.whenData((d) => storage.saveBeaResponse(d, EconIds.beaRealGdp)),
    );
    ref.listen<AsyncValue<BeaResponse>>(
      beaCorePceProvider,
      (_, next) =>
          next.whenData((d) => storage.saveBeaResponse(d, EconIds.beaCorePce)),
    );
    ref.listen<AsyncValue<BeaResponse>>(
      beaPersonalIncomeProvider,
      (_, next) => next.whenData(
        (d) => storage.saveBeaResponse(d, EconIds.beaPersonalIncome),
      ),
    );
    ref.listen<AsyncValue<BeaResponse>>(
      beaCorporateProfitsProvider,
      (_, next) => next.whenData(
        (d) => storage.saveBeaResponse(d, EconIds.beaCorporateProfits),
      ),
    );
    ref.listen<AsyncValue<BeaResponse>>(
      beaNetExportsProvider,
      (_, next) => next.whenData(
        (d) => storage.saveBeaResponse(d, EconIds.beaNetExports),
      ),
    );
    ref.listen<AsyncValue<BeaResponse>>(
      beaPceProvider,
      (_, next) =>
          next.whenData((d) => storage.saveBeaResponse(d, EconIds.beaPce)),
    );

    // ── EIA — persist each series ─────────────────────────────────────────────
    ref.listen<AsyncValue<EiaResponse>>(
      eiaGasolinePricesProvider,
      (_, next) => next.whenData(
        (d) => storage.saveEiaResponse(d, EconIds.eiaGasolinePrice),
      ),
    );
    ref.listen<AsyncValue<EiaResponse>>(
      eiaCrudeStocksProvider,
      (_, next) => next.whenData(
        (d) => storage.saveEiaResponse(d, EconIds.eiaCrudeStocks),
      ),
    );
    ref.listen<AsyncValue<EiaResponse>>(
      eiaCrudeProdProvider,
      (_, next) => next.whenData(
        (d) => storage.saveEiaResponse(d, EconIds.eiaCrudeProd),
      ),
    );
    ref.listen<AsyncValue<EiaResponse>>(
      eiaNatGasStorageProvider,
      (_, next) => next.whenData(
        (d) => storage.saveEiaResponse(d, EconIds.eiaNatGasStorage),
      ),
    );
    ref.listen<AsyncValue<EiaResponse>>(
      eiaRefineryUtilProvider,
      (_, next) => next.whenData(
        (d) => storage.saveEiaResponse(d, EconIds.eiaRefineryUtil),
      ),
    );
    ref.listen<AsyncValue<EiaResponse>>(
      eiaSprProvider,
      (_, next) =>
          next.whenData((d) => storage.saveEiaResponse(d, EconIds.eiaSpr)),
    );

    // ── Census — persist each series ──────────────────────────────────────────
    ref.listen<AsyncValue<CensusResponse>>(
      censusRetailSalesProvider,
      (_, next) => next.whenData(
        (d) => storage.saveCensusResponse(d, EconIds.censusRetailTotal),
      ),
    );
    ref.listen<AsyncValue<CensusResponse>>(
      censusMotorVehiclesProvider,
      (_, next) => next.whenData(
        (d) => storage.saveCensusResponse(d, EconIds.censusRetailVehicles),
      ),
    );
    ref.listen<AsyncValue<CensusResponse>>(
      censusNonStoreProvider,
      (_, next) => next.whenData(
        (d) => storage.saveCensusResponse(d, EconIds.censusRetailNonStore),
      ),
    );
    ref.listen<AsyncValue<CensusResponse>>(
      censusConstructionSpendingProvider,
      (_, next) => next.whenData(
        (d) => storage.saveCensusResponse(d, EconIds.censusConstruction),
      ),
    );
    ref.listen<AsyncValue<CensusResponse>>(
      censusManufacturingOrdersProvider,
      (_, next) => next.whenData(
        (d) => storage.saveCensusResponse(d, EconIds.censusMfgOrders),
      ),
    );
    ref.listen<AsyncValue<CensusResponse>>(
      censusWholesaleSalesProvider,
      (_, next) => next.whenData(
        (d) => storage.saveCensusResponse(d, EconIds.censusWholesale),
      ),
    );

    // ── FRED — persist all snapshot series ───────────────────────────────────
    ref.listen<AsyncValue<FredSeries>>(fredMortgageRateProvider,
        (_, next) => next.whenData(saveFredMortgageRate));
    ref.listen<AsyncValue<FredSeries>>(fredTreasury1yProvider,
        (_, next) => next.whenData(saveFredTreasury1y));
    ref.listen<AsyncValue<FredSeries>>(fredTreasury2yProvider,
        (_, next) => next.whenData(saveFredTreasury2y));
    ref.listen<AsyncValue<FredSeries>>(fredTreasury5yProvider,
        (_, next) => next.whenData(saveFredTreasury5y));
    ref.listen<AsyncValue<FredSeries>>(fredTreasury10yProvider,
        (_, next) => next.whenData(saveFredTreasury10y));
    ref.listen<AsyncValue<FredSeries>>(fredTreasury20yProvider,
        (_, next) => next.whenData(saveFredTreasury20y));
    ref.listen<AsyncValue<FredSeries>>(fredTreasury30yProvider,
        (_, next) => next.whenData(saveFredTreasury30y));
    ref.listen<AsyncValue<FredSeries>>(fredCrudeOilProvider,
        (_, next) => next.whenData(saveFredCrudeOil));
    ref.listen<AsyncValue<FredSeries>>(fredNatGasProvider,
        (_, next) => next.whenData(saveFredNatGas));
    ref.listen<AsyncValue<FredSeries>>(fredUnemploymentRateProvider,
        (_, next) => next.whenData(saveFredUnemploymentRate));
    ref.listen<AsyncValue<FredSeries>>(fredNonfarmPayrollsProvider,
        (_, next) => next.whenData(saveFredNonfarmPayrolls));
    ref.listen<AsyncValue<FredSeries>>(fredInitialClaimsProvider,
        (_, next) => next.whenData(saveFredInitialClaims));
    ref.listen<AsyncValue<FredSeries>>(fredConsumerSentimentProvider,
        (_, next) => next.whenData(saveFredConsumerSentiment));
    ref.listen<AsyncValue<FredSeries>>(fredCpiProvider,
        (_, next) => next.whenData(saveFredCpi));
    ref.listen<AsyncValue<FredSeries>>(fredRealGdpProvider,
        (_, next) => next.whenData(saveFredRealGdp));
    ref.listen<AsyncValue<FredSeries>>(fredRetailSalesProvider,
        (_, next) => next.whenData(saveFredRetailSales));
    ref.listen<AsyncValue<FredSeries>>(fredRecessionProbProvider,
        (_, next) => next.whenData(saveFredRecessionProb));
    ref.listen<AsyncValue<FredSeries>>(fredHousingStartsProvider,
        (_, next) => next.whenData(saveFredHousingStarts));

    return DefaultTabController(
      length: 8,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Economy Pulse'),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Refresh',
              onPressed: () {
                ref.invalidate(economyPulseProvider);
                ref.invalidate(blsEmploymentProvider);
                ref.invalidate(blsCpiProvider);
                ref.invalidate(blsPpiProvider);
                ref.invalidate(blsJoltsProvider);
                ref.invalidate(beaGdpProvider);
                ref.invalidate(beaRealGdpProvider);
                ref.invalidate(beaCorePceProvider);
                ref.invalidate(beaPersonalIncomeProvider);
                ref.invalidate(beaCorporateProfitsProvider);
                ref.invalidate(beaNetExportsProvider);
                ref.invalidate(beaPceProvider);
                ref.invalidate(eiaGasolinePricesProvider);
                ref.invalidate(eiaCrudeStocksProvider);
                ref.invalidate(eiaCrudeProdProvider);
                ref.invalidate(eiaNatGasStorageProvider);
                ref.invalidate(eiaRefineryUtilProvider);
                ref.invalidate(eiaSprProvider);
                ref.invalidate(censusRetailSalesProvider);
                ref.invalidate(censusMotorVehiclesProvider);
                ref.invalidate(censusNonStoreProvider);
                ref.invalidate(censusConstructionSpendingProvider);
                ref.invalidate(censusManufacturingOrdersProvider);
                ref.invalidate(censusWholesaleSalesProvider);
                ref.invalidate(fredVixProvider);
                ref.invalidate(fredGoldProvider);
                ref.invalidate(fredSilverProvider);
                ref.invalidate(fredHyOasProvider);
                ref.invalidate(fredIgOasProvider);
                ref.invalidate(fredSpreadProvider);
                ref.invalidate(fredFedFundsProvider);
                ref.invalidate(fredMortgageRateProvider);
                ref.invalidate(fredTreasury1yProvider);
                ref.invalidate(fredTreasury2yProvider);
                ref.invalidate(fredTreasury5yProvider);
                ref.invalidate(fredTreasury10yProvider);
                ref.invalidate(fredTreasury20yProvider);
                ref.invalidate(fredTreasury30yProvider);
                ref.invalidate(fredCrudeOilProvider);
                ref.invalidate(fredNatGasProvider);
                ref.invalidate(fredUnemploymentRateProvider);
                ref.invalidate(fredNonfarmPayrollsProvider);
                ref.invalidate(fredInitialClaimsProvider);
                ref.invalidate(fredConsumerSentimentProvider);
                ref.invalidate(fredCpiProvider);
                ref.invalidate(fredRealGdpProvider);
                ref.invalidate(fredRetailSalesProvider);
                ref.invalidate(fredRecessionProbProvider);
                ref.invalidate(fredHousingStartsProvider);
                ref.invalidate(kalshiMacroEventsProvider);
              },
            ),
            const AppMenuButton(),
          ],
          bottom: const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: 'Snapshot'),
              Tab(text: 'Charts'),
              Tab(text: 'BLS'),
              Tab(text: 'BEA'),
              Tab(text: 'EIA'),
              Tab(text: 'Census'),
              Tab(text: 'FRED'),
              Tab(text: 'Kalshi'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            pulseAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.wifi_off_outlined,
                      size: 48,
                      color: AppTheme.neutralColor,
                    ),
                    const SizedBox(height: 12),
                    const Text('Could not load economic data'),
                    const SizedBox(height: 8),
                    FilledButton(
                      onPressed: () => ref.invalidate(economyPulseProvider),
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
              data: (data) => _PulseBody(quotes: data),
            ),
            const EconomyChartsTab(),
            const BlsTab(),
            const BeaTab(),
            const EiaTab(),
            const CensusTab(),
            const FredTab(),
            const KalshiTab(),
          ],
        ),
      ),
    );
  }
}

// ─── Body ─────────────────────────────────────────────────────────────────────

class _PulseBody extends ConsumerWidget {
  final EconomyPulseData quotes;
  const _PulseBody({required this.quotes});

  // Observations are newest-first from the FRED edge function (sort_order=desc).
  // Use obs.first for latest, obs[1] for previous.

  EconomicIndicatorPoint? _point(AsyncValue<FredSeries> av, String id) =>
      av.whenOrNull(data: (s) {
        if (s.observations.isEmpty) return null;
        final o = s.observations.first;
        return EconomicIndicatorPoint(identifier: id, date: o.date, value: o.value);
      });

  StockQuote? _fredQuote(AsyncValue<FredSeries> av, String symbol) =>
      av.whenOrNull(data: (s) {
        final obs = s.observations;
        if (obs.isEmpty) return null;
        final latest = obs.first;
        final prev = obs.length >= 2 ? obs[1] : null;
        final change = prev != null ? latest.value - prev.value : 0.0;
        final changePct = (prev != null && prev.value != 0)
            ? change / prev.value * 100
            : 0.0;
        return StockQuote(
          symbol: symbol,
          name: symbol,
          price: latest.value,
          change: change,
          changePercent: changePct,
          open: prev?.value ?? latest.value,
          dayHigh: latest.value,
          dayLow: latest.value,
          previousClose: prev?.value ?? latest.value,
          volume: 0,
          dividendYield: 0.0,
        );
      });

  // NFP: PAYEMS is in thousands of persons; return MoM change converted to persons.
  EconomicIndicatorPoint? _nfpChange(AsyncValue<FredSeries> av) =>
      av.whenOrNull(data: (s) {
        final obs = s.observations;
        if (obs.length < 2) return null;
        final change = (obs.first.value - obs[1].value) * 1000;
        return EconomicIndicatorPoint(
            identifier: 'nfp', date: obs.first.date, value: change);
      });

  // CPI: compute YoY% from CPIAUCSL level using observation closest to 12 months prior.
  EconomicIndicatorPoint? _cpiYoY(AsyncValue<FredSeries> av) =>
      av.whenOrNull(data: (s) {
        final obs = s.observations;
        if (obs.length < 2) return null;
        final latest = obs.first;
        final target = DateTime(latest.date.year - 1, latest.date.month, latest.date.day);
        FredObservation? yearAgo;
        int minDiff = 999999;
        for (final o in obs) {
          final diff = o.date.difference(target).inDays.abs();
          if (diff < minDiff) {
            minDiff = diff;
            yearAgo = o;
          }
        }
        if (yearAgo == null || yearAgo.value == 0 || minDiff > 45) return null;
        final yoy = (latest.value / yearAgo.value - 1) * 100;
        return EconomicIndicatorPoint(
            identifier: 'cpi_yoy', date: latest.date, value: yoy);
      });

  double? _yieldValue(AsyncValue<FredSeries> av) =>
      av.whenOrNull(data: (s) => s.observations.isEmpty ? null : s.observations.first.value);

  DateTime? _yieldDate(AsyncValue<FredSeries> av) =>
      av.whenOrNull(data: (s) => s.observations.isEmpty ? null : s.observations.first.date);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // ── FRED snapshot providers ───────────────────────────────────────────────
    final dff      = ref.watch(fredFedFundsProvider);
    final mortgage = ref.watch(fredMortgageRateProvider);
    final gs2      = ref.watch(fredTreasury2yProvider);
    final gs5      = ref.watch(fredTreasury5yProvider);
    final gs10     = ref.watch(fredTreasury10yProvider);
    final gs30     = ref.watch(fredTreasury30yProvider);
    final gold     = ref.watch(fredGoldProvider);
    final silver   = ref.watch(fredSilverProvider);
    final crude    = ref.watch(fredCrudeOilProvider);
    final natGas   = ref.watch(fredNatGasProvider);
    final unrate   = ref.watch(fredUnemploymentRateProvider);
    final payems   = ref.watch(fredNonfarmPayrollsProvider);
    final icsa     = ref.watch(fredInitialClaimsProvider);
    final umcsent  = ref.watch(fredConsumerSentimentProvider);
    final cpi      = ref.watch(fredCpiProvider);
    final gdp      = ref.watch(fredRealGdpProvider);
    final retail   = ref.watch(fredRetailSalesProvider);
    final recProb  = ref.watch(fredRecessionProbProvider);
    final housing  = ref.watch(fredHousingStartsProvider);

    final fetchTime =
        '${quotes.fetchedAt.hour.toString().padLeft(2, '0')}:${quotes.fetchedAt.minute.toString().padLeft(2, '0')}';

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        Text(
          'Updated $fetchTime',
          style: const TextStyle(color: AppTheme.neutralColor, fontSize: 11),
        ),
        const SizedBox(height: 16),

        // ── Market Snapshot (Schwab live quotes) ──────────────────────────
        _SectionHeader('Market Snapshot'),
        _TileGrid(
          children: [
            _QuoteTile(label: 'S&P 500', sublabel: 'SPY', quote: quotes.sp500),
            _QuoteTile(label: 'Nasdaq 100', sublabel: 'QQQ', quote: quotes.nasdaq),
            _QuoteTile(
              label: 'VIX',
              sublabel: 'Fear Index',
              quote: quotes.vix,
              invertColor: true,
            ),
            _QuoteTile(label: 'Dollar Index', sublabel: 'DXY', quote: quotes.dxy),
          ],
        ),
        const SizedBox(height: 20),

        // ── Market Movers (Schwab) ────────────────────────────────────────
        const _MoversSection(),
        const SizedBox(height: 20),

        // ── Interest Rates (FRED) ─────────────────────────────────────────
        _SectionHeader('Interest Rates'),
        _TileGrid(
          children: [
            _EconTile(
              label: 'Fed Funds',
              sublabel: 'Target Rate',
              point: _point(dff, FredStorageIds.fedFunds),
              format: _fmtPct,
            ),
            _EconTile(
              label: 'Mortgage 30Y',
              sublabel: 'Fixed Rate Avg',
              point: _point(mortgage, FredStorageIds.mortgageRate30y),
              format: _fmtPct,
            ),
            _YieldTile(label: '2Y Treasury',  value: _yieldValue(gs2),  date: _yieldDate(gs2)),
            _YieldTile(label: '10Y Treasury', value: _yieldValue(gs10), date: _yieldDate(gs10)),
            _YieldTile(label: '5Y Treasury',  value: _yieldValue(gs5),  date: _yieldDate(gs5)),
            _YieldTile(label: '30Y Treasury', value: _yieldValue(gs30), date: _yieldDate(gs30)),
          ],
        ),
        const SizedBox(height: 20),

        // ── Commodities (FRED daily prices) ───────────────────────────────
        _SectionHeader('Commodities'),
        _TileGrid(
          children: [
            _QuoteTile(
              label: 'Gold',
              sublabel: 'LBMA Fix',
              quote: _fredQuote(gold, 'GOLD'),
              pricePrefix: '\$',
            ),
            _QuoteTile(
              label: 'Silver',
              sublabel: 'Spot',
              quote: _fredQuote(silver, 'SILVER'),
              pricePrefix: '\$',
            ),
            _QuoteTile(
              label: 'WTI Crude',
              sublabel: r'$/bbl',
              quote: _fredQuote(crude, 'WTI'),
              pricePrefix: '\$',
            ),
            _QuoteTile(
              label: 'Natural Gas',
              sublabel: 'Henry Hub',
              quote: _fredQuote(natGas, 'NATGAS'),
              pricePrefix: '\$',
            ),
          ],
        ),
        const SizedBox(height: 20),

        // ── Labor Market (FRED) ───────────────────────────────────────────
        _SectionHeader('Labor Market'),
        _TileGrid(
          children: [
            _EconTile(
              label: 'Unemployment',
              sublabel: 'Rate',
              point: _point(unrate, FredStorageIds.unemploymentRate),
              format: _fmtPct,
              warnHigh: true,
            ),
            _EconTile(
              label: 'Non-Farm Payrolls',
              sublabel: 'Jobs Added',
              point: _nfpChange(payems),
              format: _fmtJobsK,
              showSign: true,
            ),
            _EconTile(
              label: 'Initial Claims',
              sublabel: 'Weekly Jobless',
              point: _point(icsa, FredStorageIds.initialClaims),
              format: _fmtJobsK,
              warnHigh: true,
            ),
            _EconTile(
              label: 'Consumer Sentiment',
              sublabel: 'Univ. of Michigan',
              point: _point(umcsent, FredStorageIds.consumerSentiment),
              format: _fmtNum,
            ),
          ],
        ),
        const SizedBox(height: 20),

        // ── Economy (FRED) ────────────────────────────────────────────────
        _SectionHeader('Economy'),
        _TileGrid(
          children: [
            _EconTile(
              label: 'CPI',
              sublabel: 'Inflation YoY',
              point: _cpiYoY(cpi),
              format: _fmtPct,
              warnHigh: true,
            ),
            _EconTile(
              label: 'Real GDP',
              sublabel: 'Chained 2017\$',
              point: _point(gdp, FredStorageIds.realGdp),
              format: _fmtGdp,
            ),
            _EconTile(
              label: 'Retail Sales',
              sublabel: 'Ex-auto (M)',
              point: _point(retail, FredStorageIds.retailSales),
              format: _fmtRetail,
            ),
            _EconTile(
              label: 'Recession Prob.',
              sublabel: 'Smoothed Model',
              point: _point(recProb, FredStorageIds.recessionProb),
              format: _fmtPct,
              warnHigh: true,
            ),
          ],
        ),
        const SizedBox(height: 20),

        // ── Housing (FRED) ────────────────────────────────────────────────
        _SectionHeader('Housing'),
        _TileGrid(
          children: [
            _EconTile(
              label: 'Housing Starts',
              sublabel: 'New Units (K, SAAR)',
              point: _point(housing, FredStorageIds.housingStarts),
              format: _fmtHousing,
            ),
          ],
        ),
      ],
    );
  }
}

// ─── Market Movers ────────────────────────────────────────────────────────────

class _MoversSection extends ConsumerStatefulWidget {
  const _MoversSection();

  @override
  ConsumerState<_MoversSection> createState() => _MoversSectionState();
}

class _MoversSectionState extends ConsumerState<_MoversSection> {
  String _symbolId = r'$SPX';
  String _sort     = 'PERCENT_CHANGE_UP';

  static const _indices = [r'$SPX', r'$COMPX', r'$DJI'];
  static const _indexLabels = ['S&P 500', 'Nasdaq', 'Dow Jones'];

  @override
  Widget build(BuildContext context) {
    final movers = ref.watch(
      moversProvider(MoversParams(symbolId: _symbolId, sort: _sort)),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader('Market Movers'),
        // Index selector + up/down toggle
        Row(
          children: [
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: List.generate(_indices.length, (i) {
                    final selected = _symbolId == _indices[i];
                    return Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        label: Text(_indexLabels[i]),
                        selected: selected,
                        onSelected: (_) => setState(() => _symbolId = _indices[i]),
                        visualDensity: VisualDensity.compact,
                      ),
                    );
                  }),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: Icon(
                _sort == 'PERCENT_CHANGE_UP'
                    ? Icons.trending_up
                    : Icons.trending_down,
                color: _sort == 'PERCENT_CHANGE_UP'
                    ? AppTheme.profitColor
                    : AppTheme.lossColor,
              ),
              tooltip: _sort == 'PERCENT_CHANGE_UP' ? 'Showing gainers' : 'Showing losers',
              onPressed: () => setState(() {
                _sort = _sort == 'PERCENT_CHANGE_UP'
                    ? 'PERCENT_CHANGE_DOWN'
                    : 'PERCENT_CHANGE_UP';
              }),
            ),
          ],
        ),
        const SizedBox(height: 8),
        movers.when(
          loading: () => const Center(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: CircularProgressIndicator(),
            ),
          ),
          error: (e, _) => const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('Could not load movers',
                style: TextStyle(color: AppTheme.neutralColor)),
          ),
          data: (list) => list.isEmpty
              ? const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text('No movers data available',
                      style: TextStyle(color: AppTheme.neutralColor)),
                )
              : Container(
                  decoration: BoxDecoration(
                    color: AppTheme.cardColor,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppTheme.borderColor),
                  ),
                  child: Column(
                    children: List.generate(list.length, (i) {
                      final m = list[i];
                      final isUp = m.isUp;
                      final changeColor =
                          isUp ? AppTheme.profitColor : AppTheme.lossColor;
                      final sign = isUp ? '+' : '';
                      return Column(
                        children: [
                          Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 10),
                            child: Row(
                              children: [
                                // Rank
                                SizedBox(
                                  width: 20,
                                  child: Text('${i + 1}',
                                      style: const TextStyle(
                                          color: AppTheme.neutralColor,
                                          fontSize: 11)),
                                ),
                                const SizedBox(width: 8),
                                // Symbol + name
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(m.symbol,
                                          style: const TextStyle(
                                              fontWeight: FontWeight.w700,
                                              fontSize: 13)),
                                      Text(m.description,
                                          style: const TextStyle(
                                              color: AppTheme.neutralColor,
                                              fontSize: 11),
                                          overflow: TextOverflow.ellipsis),
                                    ],
                                  ),
                                ),
                                // Volume
                                Padding(
                                  padding: const EdgeInsets.only(right: 12),
                                  child: Text(
                                    _fmtVolume(m.totalVolume),
                                    style: const TextStyle(
                                        color: AppTheme.neutralColor,
                                        fontSize: 11),
                                  ),
                                ),
                                // Price + change
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Text('\$${m.last.toStringAsFixed(2)}',
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w600,
                                            fontSize: 13)),
                                    Text('$sign${m.change.toStringAsFixed(2)}%',
                                        style: TextStyle(
                                            color: changeColor,
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600)),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          if (i < list.length - 1)
                            Divider(
                                height: 1,
                                color: AppTheme.borderColor.withValues(alpha: 0.5)),
                        ],
                      );
                    }),
                  ),
                ),
        ),
      ],
    );
  }

  static String _fmtVolume(int v) {
    if (v >= 1000000) return '${(v / 1000000).toStringAsFixed(1)}M';
    if (v >= 1000)    return '${(v / 1000).toStringAsFixed(0)}K';
    return '$v';
  }
}

// ─── Formatters ───────────────────────────────────────────────────────────────

String _fmtPct(double v) => '${v.toStringAsFixed(2)}%';
String _fmtNum(double v) => v.toStringAsFixed(1);
String _fmtJobsK(double v) {
  final k = v / 1000;
  return k >= 1000
      ? '${(k / 1000).toStringAsFixed(1)}M'
      : '${k.toStringAsFixed(0)}K';
}

String _fmtGdp(double v) {
  // Real GDP stored in billions
  if (v >= 1000) return '\$${(v / 1000).toStringAsFixed(1)}T';
  return '\$${v.toStringAsFixed(0)}B';
}

String _fmtRetail(double v) {
  if (v.abs() >= 1000) return '\$${(v / 1000).toStringAsFixed(1)}B';
  return '\$${v.toStringAsFixed(0)}M';
}

String _fmtHousing(double v) {
  // Housing starts stored in thousands of units
  return '${v.toStringAsFixed(0)}K';
}

String _fmtDate(DateTime d) => DateFormat('MMM yyyy').format(d);

// ─── Layout widgets ───────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
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
}

class _TileGrid extends StatelessWidget {
  final List<Widget> children;
  const _TileGrid({required this.children});

  @override
  Widget build(BuildContext context) {
    // Pair children into rows of 2
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i += 2) {
      final hasSecond = i + 1 < children.length;
      rows.add(
        Row(
          children: [
            Expanded(child: children[i]),
            const SizedBox(width: 8),
            Expanded(child: hasSecond ? children[i + 1] : const SizedBox()),
          ],
        ),
      );
      if (i + 2 < children.length) rows.add(const SizedBox(height: 8));
    }
    return Column(children: rows);
  }
}

// ─── Tile types ───────────────────────────────────────────────────────────────

// Base tile container
class _Tile extends StatelessWidget {
  final Widget child;
  const _Tile({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.cardColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.borderColor),
      ),
      child: child,
    );
  }
}

// Live asset quote tile (price + change%)
class _QuoteTile extends StatelessWidget {
  final String label;
  final String sublabel;
  final StockQuote? quote;
  final bool invertColor; // VIX: high = bad (red)
  final String pricePrefix;

  const _QuoteTile({
    required this.label,
    required this.sublabel,
    required this.quote,
    this.invertColor = false,
    this.pricePrefix = '',
  });

  @override
  Widget build(BuildContext context) {
    if (quote == null) {
      return _Tile(child: _PlaceholderContent(label, sublabel));
    }

    final isPos = quote!.changePercent >= 0;
    final positive = invertColor ? !isPos : isPos;
    final changeColor = positive ? AppTheme.profitColor : AppTheme.lossColor;
    final sign = quote!.changePercent >= 0 ? '+' : '';

    return _Tile(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _TileLabel(label, sublabel),
          const SizedBox(height: 6),
          Text(
            '$pricePrefix${_fmtPrice(quote!.price)}',
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '$sign${quote!.changePercent.toStringAsFixed(2)}%',
            style: TextStyle(
              color: changeColor,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  static String _fmtPrice(double p) {
    if (p >= 1000) return p.toStringAsFixed(0);
    if (p >= 100) return p.toStringAsFixed(2);
    return p.toStringAsFixed(2);
  }
}

// Economic indicator tile (lagging data + report date)
class _EconTile extends StatelessWidget {
  final String label;
  final String sublabel;
  final EconomicIndicatorPoint? point;
  final String Function(double) format;
  final bool warnHigh; // high value = yellow/red warning (unemployment, CPI)
  final bool showSign;

  const _EconTile({
    required this.label,
    required this.sublabel,
    required this.point,
    required this.format,
    this.warnHigh = false,
    this.showSign = false,
  });

  @override
  Widget build(BuildContext context) {
    if (point == null) {
      return _Tile(child: _PlaceholderContent(label, sublabel));
    }

    Color valueColor = Colors.white;
    if (warnHigh) {
      // No threshold — show neutral. Could add thresholds later.
      valueColor = Colors.white;
    }

    final raw = format(point!.value);
    final display = showSign && point!.value >= 0 ? '+$raw' : raw;

    return _Tile(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _TileLabel(label, sublabel),
          const SizedBox(height: 6),
          Text(
            display,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.5,
              color: valueColor,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            _fmtDate(point!.date),
            style: const TextStyle(color: AppTheme.neutralColor, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

// Treasury yield tile (single maturity value)
class _YieldTile extends StatelessWidget {
  final String label;
  final double? value;
  final DateTime? date;

  const _YieldTile({
    required this.label,
    required this.value,
    required this.date,
  });

  @override
  Widget build(BuildContext context) {
    if (value == null) {
      return _Tile(child: _PlaceholderContent(label, 'Treasury'));
    }

    return _Tile(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _TileLabel(label, 'Treasury'),
          const SizedBox(height: 6),
          Text(
            '${value!.toStringAsFixed(2)}%',
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            date != null ? _fmtDate(date!) : '—',
            style: const TextStyle(color: AppTheme.neutralColor, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

// Shared label row used inside every tile
class _TileLabel extends StatelessWidget {
  final String title;
  final String sub;
  const _TileLabel(this.title, this.sub);

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: Colors.white,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        Text(
          sub,
          style: const TextStyle(color: AppTheme.neutralColor, fontSize: 10),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

class _PlaceholderContent extends StatelessWidget {
  final String label;
  final String sub;
  const _PlaceholderContent(this.label, this.sub);

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _TileLabel(label, sub),
        const SizedBox(height: 6),
        const Text(
          '—',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: AppTheme.neutralColor,
          ),
        ),
        const SizedBox(height: 2),
        const Text(
          'No data',
          style: TextStyle(color: AppTheme.neutralColor, fontSize: 11),
        ),
      ],
    );
  }
}
