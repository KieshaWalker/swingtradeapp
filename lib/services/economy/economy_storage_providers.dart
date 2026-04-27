// =============================================================================
// services/economy/economy_storage_providers.dart
// =============================================================================
// Riverpod providers that read economy history from Supabase.
//
//   economyStorageServiceProvider         — EconomyStorageService singleton
//   economyIndicatorHistoryProvider(id)   — history for one economic indicator
//   economyQuoteHistoryProvider(symbol)   — daily price history for one symbol
//   economyTreasuryHistoryProvider        — all stored treasury yield curves
// =============================================================================
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../features/auth/providers/auth_provider.dart';
import '../schwab/schwab_models.dart';
import 'economy_snapshot_models.dart';
import 'economy_storage_service.dart';

final economyStorageServiceProvider = Provider<EconomyStorageService>((ref) {
  return EconomyStorageService(ref.watch(supabaseClientProvider));
});

final economyIndicatorHistoryProvider =
    FutureProvider.family<List<EconomicIndicatorPoint>, String>(
        (ref, identifier) {
  return ref
      .read(economyStorageServiceProvider)
      .getIndicatorHistory(identifier);
});

final economyQuoteHistoryProvider =
    FutureProvider.family<List<QuoteSnapshot>, String>((ref, symbol) {
  return ref.read(economyStorageServiceProvider).getQuoteHistory(symbol);
});

final economyTreasuryHistoryProvider =
    FutureProvider<List<TreasurySnapshot>>((ref) {
  return ref.read(economyStorageServiceProvider).getTreasuryHistory();
});

final natGasImportPricesProvider =
    FutureProvider<List<NatGasImportPoint>>((ref) {
  return ref.read(economyStorageServiceProvider).getNatGasImportHistory();
});

final unemploymentRateHistoryProvider =
    FutureProvider<List<UnemploymentRatePoint>>((ref) {
  return ref.read(economyStorageServiceProvider).getUnemploymentHistory();
});

final gasolinePriceHistoryStorageProvider =
    FutureProvider<List<GasolinePricePoint>>((ref) {
  return ref.read(economyStorageServiceProvider).getGasolinePriceHistory();
});
