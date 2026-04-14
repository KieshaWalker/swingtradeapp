// =============================================================================
// vol_surface/providers/vol_surface_provider.dart
// =============================================================================
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../services/schwab/schwab_models.dart';
import '../models/vol_surface_models.dart';
import '../services/vol_surface_parser.dart';
import '../services/vol_surface_repository.dart';

final _repoProvider = Provider<VolSurfaceRepository>(
  (_) => VolSurfaceRepository(Supabase.instance.client),
);

class VolSurfaceNotifier extends AsyncNotifier<List<VolSnapshot>> {
  @override
  Future<List<VolSnapshot>> build() =>
      ref.read(_repoProvider).loadAll();

  Future<void> save(VolSnapshot snap) async {
    await ref.read(_repoProvider).save(snap);
    ref.invalidateSelf();
  }

  Future<void> delete(VolSnapshot snap) async {
    await ref.read(_repoProvider).delete(snap);
    ref.invalidateSelf();
  }

  Future<void> deleteByTicker(String ticker) async {
    await ref.read(_repoProvider).deleteByTicker(ticker);
    ref.invalidateSelf();
  }
}

final volSurfaceProvider =
    AsyncNotifierProvider<VolSurfaceNotifier, List<VolSnapshot>>(
  VolSurfaceNotifier.new,
);

/// Called from OptionsChainScreen once per chain load to silently persist a
/// vol surface snapshot. Mirrors autoIngestIv — errors are swallowed so they
/// never disrupt the options chain UI. The upsert key is (user_id, ticker,
/// obs_date) so repeated views on the same day overwrite with the latest data.
Future<void> autoIngestVolSurface(SchwabOptionsChain chain) async {
  try {
    final snap = VolSurfaceParser.fromChain(chain);
    if (snap.points.isEmpty) return;
    await VolSurfaceRepository(Supabase.instance.client).save(snap);
  } catch (_) {
    // Never disrupt the options chain UI on ingestion failure.
  }
}
