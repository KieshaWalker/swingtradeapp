// =============================================================================
// vol_surface/providers/vol_surface_provider.dart
// =============================================================================
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../services/schwab/schwab_models.dart';
import '../../../services/schwab/schwab_service.dart';
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
/// vol surface snapshot from the already-fetched chain. Pass the live chain
/// so the heatmap always reflects exactly what the options chain screen shows.
/// If the chain has too few strikes (user narrowed the view), a fresh wide
/// fetch is done at strikeCount: 40 to ensure surface coverage.
/// Errors are swallowed to never disrupt the UI.
Future<void> autoIngestVolSurface(
  String symbol, {
  SchwabOptionsChain? chain,
}) async {
  try {
    SchwabOptionsChain? source = chain;
    if (source == null || source.expirations.length < 2) {
      source = await SchwabService().getOptionsChain(
        symbol,
        contractType: 'ALL',
        strikeCount: 40,
      );
    }
    if (source == null || source.expirations.isEmpty) return;
    final snap = VolSurfaceParser.fromChain(source);
    if (snap.points.isEmpty) return;
    await VolSurfaceRepository(Supabase.instance.client).save(snap);
  } catch (_) {
    // Never disrupt the options chain UI on ingestion failure.
  }
}
