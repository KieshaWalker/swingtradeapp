// =============================================================================
// services/economy/economy_storage_service.dart
// =============================================================================
// Persists EconomyPulseData, BLS, BEA, EIA, and Census data to Supabase
// and reads back history for charts.
//
// Tables written:
//   economy_indicator_snapshots  — one row per (identifier, date)
//   economy_treasury_snapshots   — one row per date
//   economy_quote_snapshots      — one row per (symbol, date)
//
// All writes are upserts (on-conflict do update) so repeated fetches on the
// same day are idempotent.
// =============================================================================
import 'package:supabase_flutter/supabase_flutter.dart';
import '../fmp/fmp_models.dart';
import '../bls/bls_models.dart';
import '../bea/bea_models.dart';
import '../eia/eia_models.dart';
import '../census/census_models.dart';
import 'economy_snapshot_models.dart';

// ── Identifier constants shared by storage service and chart widgets ──────────

abstract class EconIds {
  // BLS Employment
  static const blsUnemploymentU3       = 'bls_unemployment_u3';
  static const blsUnemploymentU6       = 'bls_unemployment_u6';
  static const blsNfp                  = 'bls_nfp';
  static const blsLfpr                 = 'bls_lfpr';
  static const blsAvgHourlyEarnings    = 'bls_avg_hourly_earnings';
  static const blsAvgWeeklyHours       = 'bls_avg_weekly_hours';
  // BLS CPI
  static const blsCpiAll               = 'bls_cpi_all';
  static const blsCpiCore              = 'bls_cpi_core';
  static const blsCpiShelter           = 'bls_cpi_shelter';
  static const blsCpiFood              = 'bls_cpi_food';
  static const blsCpiEnergy            = 'bls_cpi_energy';
  // BLS PPI
  static const blsPpiFinal             = 'bls_ppi_final';
  static const blsPpiCore              = 'bls_ppi_core';
  static const blsPpiGoods             = 'bls_ppi_goods';
  static const blsPpiServices          = 'bls_ppi_services';
  // BLS JOLTS
  static const blsJobOpenings          = 'bls_job_openings';
  static const blsJobOpeningsRate      = 'bls_job_openings_rate';
  static const blsHires                = 'bls_hires';
  static const blsQuits                = 'bls_quits';
  static const blsLayoffs              = 'bls_layoffs';
  static const blsQuitsRate            = 'bls_quits_rate';
  // BEA
  static const beaGdpPct               = 'bea_gdp_pct';
  static const beaRealGdp              = 'bea_real_gdp';
  static const beaPce                  = 'bea_pce';
  static const beaCorePce              = 'bea_core_pce';
  static const beaPersonalIncome       = 'bea_personal_income';
  static const beaCorporateProfits     = 'bea_corporate_profits';
  static const beaNetExports           = 'bea_net_exports';
  // EIA
  static const eiaGasolinePrice        = 'eia_gasoline_price';
  static const eiaCrudeStocks          = 'eia_crude_stocks';
  static const eiaCrudeProd            = 'eia_crude_prod';
  static const eiaNatGasStorage        = 'eia_natgas_storage';
  static const eiaRefineryUtil         = 'eia_refinery_util';
  static const eiaSpr                  = 'eia_spr';
  // Census
  static const censusRetailTotal       = 'census_retail_total';
  static const censusRetailVehicles    = 'census_retail_vehicles';
  static const censusRetailNonStore    = 'census_retail_nonstore';
  static const censusConstruction      = 'census_construction';
  static const censusMfgOrders         = 'census_mfg_orders';
  static const censusWholesale         = 'census_wholesale';

  // Maps BLS series ID → EconIds identifier
  static const Map<String, String> blsSeriesMap = {
    BlsSeriesIds.unemploymentRateU3:             blsUnemploymentU3,
    BlsSeriesIds.totalNonfarmPayrolls:           blsNfp,
    BlsSeriesIds.laborForceParticipationRate:    blsLfpr,
    BlsSeriesIds.avgHourlyEarningsPrivate:       blsAvgHourlyEarnings,
    BlsSeriesIds.avgWeeklyHoursPrivate:          blsAvgWeeklyHours,
    BlsSeriesIds.cpiAllItemsSA:                  blsCpiAll,
    BlsSeriesIds.cpiCore:                        blsCpiCore,
    BlsSeriesIds.cpiShelter:                     blsCpiShelter,
    BlsSeriesIds.cpiFood:                        blsCpiFood,
    BlsSeriesIds.cpiEnergy:                      blsCpiEnergy,
    BlsSeriesIds.ppiFinalDemand:                 blsPpiFinal,
    BlsSeriesIds.ppiFinalDemandLessFoodEnergy:   blsPpiCore,
    BlsSeriesIds.ppiFinalDemandGoods:            blsPpiGoods,
    BlsSeriesIds.ppiFinalDemandServices:         blsPpiServices,
    BlsSeriesIds.jobOpenings:                    blsJobOpenings,
    BlsSeriesIds.jobOpeningsRate:                blsJobOpeningsRate,
    BlsSeriesIds.hires:                          blsHires,
    BlsSeriesIds.quits:                          blsQuits,
    BlsSeriesIds.layoffsDischarges:              blsLayoffs,
    BlsSeriesIds.quitsRate:                      blsQuitsRate,
  };
}

// ─────────────────────────────────────────────────────────────────────────────

class EconomyStorageService {
  final SupabaseClient _db;
  const EconomyStorageService(this._db);

  // ── FMP (existing) ─────────────────────────────────────────────────────────

  Future<void> saveEconomyPulse(EconomyPulseData data) async {
    try {
      await Future.wait([
        _saveIndicators(data),
        _saveTreasury(data.treasury),
        _saveQuotes(data),
      ]);
    } catch (_) {
      // Silently ignore if tables don't exist yet (migration not applied)
    }
  }

  Future<void> _saveIndicators(EconomyPulseData data) async {
    final points = [
      data.fedFunds,
      data.unemployment,
      data.nfp,
      data.initialClaims,
      data.cpi,
      data.gdp,
      data.retailSales,
      data.consumerSentiment,
      data.mortgageRate,
      data.housingStarts,
      data.recessionProb,
    ].whereType<EconomicIndicatorPoint>().toList();

    if (points.isEmpty) return;
    await _db.from('economy_indicator_snapshots').upsert(
      points.map((p) => {
        'identifier': p.identifier,
        'date': _fmt(p.date),
        'value': p.value,
      }).toList(),
      onConflict: 'identifier,date',
    );
  }

  Future<void> _saveTreasury(TreasuryRates? treasury) async {
    if (treasury == null) return;
    await _db.from('economy_treasury_snapshots').upsert(
      {
        'date': _fmt(treasury.date),
        'year1': treasury.year1,
        'year2': treasury.year2,
        'year5': treasury.year5,
        'year10': treasury.year10,
        'year20': treasury.year20,
        'year30': treasury.year30,
      },
      onConflict: 'date',
    );
  }

  Future<void> _saveQuotes(EconomyPulseData data) async {
    final today = _fmt(data.fetchedAt);
    final quotes = [
      data.sp500, data.nasdaq, data.vix, data.dxy,
      data.gold, data.silver, data.wtiCrude, data.natGas,
    ].whereType<StockQuote>().toList();

    if (quotes.isEmpty) return;
    await _db.from('economy_quote_snapshots').upsert(
      quotes.map((q) => {
        'symbol': q.symbol,
        'date': today,
        'price': q.price,
        'change_percent': q.changePercent,
      }).toList(),
      onConflict: 'symbol,date',
    );
  }

  // ── BLS ────────────────────────────────────────────────────────────────────

  Future<void> saveBlsResponse(BlsResponse response) async {
    try {
      final rows = <Map<String, dynamic>>[];
      for (final series in response.series) {
        final id = EconIds.blsSeriesMap[series.seriesId];
        if (id == null) continue;
        for (final d in series.data) {
          if (d.value <= 0) continue; // skip "-" entries stored as 0
          final date = _blsPeriodToDate(d.year, d.period);
          if (date == null) continue;
          rows.add({'identifier': id, 'date': _fmt(date), 'value': d.value});
        }
      }
      if (rows.isEmpty) return;
      await _db.from('economy_indicator_snapshots')
          .upsert(rows, onConflict: 'identifier,date');
    } catch (_) {}
  }

  // ── BEA ────────────────────────────────────────────────────────────────────

  Future<void> saveBeaResponse(BeaResponse response, String identifier) async {
    try {
      final rows = response.data.map((obs) {
        final date = _beaPeriodToDate(obs.timePeriod);
        final v = obs.value;
        if (date == null || v == null) return null;
        return {'identifier': identifier, 'date': _fmt(date), 'value': v};
      }).whereType<Map<String, dynamic>>().toList();
      if (rows.isEmpty) return;
      await _db.from('economy_indicator_snapshots')
          .upsert(rows, onConflict: 'identifier,date');
    } catch (_) {}
  }

  // ── EIA ────────────────────────────────────────────────────────────────────

  Future<void> saveEiaResponse(EiaResponse response, String identifier) async {
    try {
      final rows = response.data.map((d) {
        if (d.value == null) return null;
        // EIA period is "2024-03-20" or "2024-03" or "2024"
        final date = DateTime.tryParse(d.period) ??
            DateTime.tryParse('${d.period}-01') ??
            DateTime.tryParse('${d.period}-01-01');
        if (date == null) return null;
        return {'identifier': identifier, 'date': _fmt(date), 'value': d.value!};
      }).whereType<Map<String, dynamic>>().toList();
      if (rows.isEmpty) return;
      await _db.from('economy_indicator_snapshots')
          .upsert(rows, onConflict: 'identifier,date');
    } catch (_) {}
  }

  // ── Census ─────────────────────────────────────────────────────────────────

  Future<void> saveCensusResponse(CensusResponse response, String identifier) async {
    try {
      final rows = response.toRetailRows().map((r) {
        if (r.value == null) return null;
        final parts = r.period.split('-');
        if (parts.length < 2) return null;
        final y = int.tryParse(parts[0]);
        final m = int.tryParse(parts[1]);
        if (y == null || m == null) return null;
        return {
          'identifier': identifier,
          'date': _fmt(DateTime(y, m, 1)),
          'value': r.value!,
        };
      }).whereType<Map<String, dynamic>>().toList();
      if (rows.isEmpty) return;
      await _db.from('economy_indicator_snapshots')
          .upsert(rows, onConflict: 'identifier,date');
    } catch (_) {}
  }

  // ── Read ───────────────────────────────────────────────────────────────────

  Future<List<EconomicIndicatorPoint>> getIndicatorHistory(
      String identifier) async {
    try {
      final rows = await _db
          .from('economy_indicator_snapshots')
          .select('identifier, date, value')
          .eq('identifier', identifier)
          .order('date');
      return rows.map<EconomicIndicatorPoint>((r) => EconomicIndicatorPoint(
            identifier: r['identifier'] as String,
            date: DateTime.parse(r['date'] as String),
            value: (r['value'] as num).toDouble(),
          )).toList();
    } catch (_) {
      return [];
    }
  }

  Future<List<QuoteSnapshot>> getQuoteHistory(String symbol) async {
    try {
      final rows = await _db
          .from('economy_quote_snapshots')
          .select('symbol, date, price, change_percent')
          .eq('symbol', symbol)
          .order('date');
      return rows.map<QuoteSnapshot>(QuoteSnapshot.fromRow).toList();
    } catch (_) {
      return [];
    }
  }

  // ── BLS unemployment rate history ─────────────────────────────────────────

  /// Upserts a single month from a BLS response into us_unemployment_rate_history.
  Future<void> saveUnemploymentHistory(BlsResponse response) async {
    try {
      final series = response.series.firstWhere(
        (s) => s.seriesId == 'LNS14000000',
        orElse: () => BlsSeries(seriesId: '', data: []),
      );
      if (series.seriesId.isEmpty) return;
      final rows = series.data.map((d) {
        final date = _blsPeriodToDate(d.year, d.period);
        if (date == null || d.value <= 0) return null;
        return {'rate_date': _fmt(date), 'unemployment_rate': d.value};
      }).whereType<Map<String, dynamic>>().toList();
      if (rows.isEmpty) return;
      await _db
          .from('us_unemployment_rate_history')
          .upsert(rows, onConflict: 'rate_date');
    } catch (_) {}
  }

  Future<List<UnemploymentRatePoint>> getUnemploymentHistory() async {
    try {
      final rows = await _db
          .from('us_unemployment_rate_history')
          .select('rate_date, unemployment_rate')
          .order('rate_date');
      return rows.map<UnemploymentRatePoint>((r) => UnemploymentRatePoint(
            date: DateTime.parse(r['rate_date'] as String),
            rate: (r['unemployment_rate'] as num).toDouble(),
          )).toList();
    } catch (_) {
      return [];
    }
  }

  // ── EIA gasoline price history ─────────────────────────────────────────────

  Future<void> saveGasolinePriceHistory(EiaResponse response) async {
    try {
      final rows = response.data.map((d) {
        if (d.value == null) return null;
        final date = DateTime.tryParse(d.period);
        if (date == null) return null;
        return {'date': _fmt(date), 'price': d.value!};
      }).whereType<Map<String, dynamic>>().toList();
      if (rows.isEmpty) return;
      await _db
          .from('us_gasoline_price_history')
          .upsert(rows, onConflict: 'date');
    } catch (_) {}
  }

  Future<List<GasolinePricePoint>> getGasolinePriceHistory() async {
    try {
      final rows = await _db
          .from('us_gasoline_price_history')
          .select('date, price')
          .order('date');
      return rows.map<GasolinePricePoint>((r) => GasolinePricePoint(
            date: DateTime.parse(r['date'] as String),
            price: (r['price'] as num).toDouble(),
          )).toList();
    } catch (_) {
      return [];
    }
  }

  Future<List<NatGasImportPoint>> getNatGasImportHistory() async {
    try {
      final rows = await _db
          .from('us_natural_gas_import_prices')
          .select()
          .order('year');
      const months = ['jan','feb','mar','apr','may','jun',
                      'jul','aug','sep','oct','nov','dec'];
      final points = <NatGasImportPoint>[];
      for (final row in rows) {
        final year = (row['year'] as int);
        for (var m = 0; m < 12; m++) {
          final v = (row[months[m]] as num?)?.toDouble();
          if (v == null) continue;
          points.add(NatGasImportPoint(date: DateTime(year, m + 1, 1), price: v));
        }
      }
      return points;
    } catch (_) {
      return [];
    }
  }

  Future<List<TreasurySnapshot>> getTreasuryHistory() async {
    try {
      final rows =
          await _db.from('economy_treasury_snapshots').select().order('date');
      return rows.map<TreasurySnapshot>(TreasurySnapshot.fromRow).toList();
    } catch (_) {
      return [];
    }
  }

  // ── Period parsers ─────────────────────────────────────────────────────────

  // BLS: year="2024", period="M03" or "Q1"
  static DateTime? _blsPeriodToDate(String year, String period) {
    final y = int.tryParse(year);
    if (y == null) return null;
    if (period.startsWith('M')) {
      final m = int.tryParse(period.substring(1));
      if (m == null || m < 1 || m > 12) return null;
      return DateTime(y, m, 1);
    }
    if (period.startsWith('Q')) {
      final q = int.tryParse(period.substring(1));
      if (q == null || q < 1 || q > 4) return null;
      return DateTime(y, (q - 1) * 3 + 1, 1);
    }
    return null;
  }

  // BEA: "2024Q3" or "2024M03" or "2024"
  static DateTime? _beaPeriodToDate(String period) {
    if (period.contains('Q')) {
      final p = period.split('Q');
      final y = int.tryParse(p[0]);
      final q = int.tryParse(p[1]);
      if (y == null || q == null) return null;
      return DateTime(y, (q - 1) * 3 + 1, 1);
    }
    if (period.contains('M')) {
      final p = period.split('M');
      final y = int.tryParse(p[0]);
      final m = int.tryParse(p[1]);
      if (y == null || m == null) return null;
      return DateTime(y, m, 1);
    }
    final y = int.tryParse(period);
    return y != null ? DateTime(y, 1, 1) : null;
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  static String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
