// =============================================================================
// vol_surface/providers/vol_surface_provider.dart
// =============================================================================
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/vol_surface_models.dart';
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
}

final volSurfaceProvider =
    AsyncNotifierProvider<VolSurfaceNotifier, List<VolSnapshot>>(
  VolSurfaceNotifier.new,
);
