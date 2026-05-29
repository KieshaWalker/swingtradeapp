import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../auth/providers/auth_provider.dart';
import '../models/macro_indicator.dart';

final macroIndicatorsProvider =
    FutureProvider<List<MacroIndicator>>((ref) async {
  final client = ref.watch(supabaseClientProvider);
  final user = client.auth.currentUser;
  if (user == null) return [];
  final rows = await client
      .from('macro_indicators')
      .select()
      .eq('user_id', user.id)
      .order('created_at', ascending: true);
  return (rows as List)
      .map((r) => MacroIndicator.fromJson(r as Map<String, dynamic>))
      .toList();
});

// Net score: sum of all weights. Positive = net bullish, negative = net bearish.
final macroNetScoreProvider = Provider<int>((ref) {
  final indicators = ref.watch(macroIndicatorsProvider).valueOrNull ?? [];
  return indicators.fold(0, (sum, i) => sum + i.weight);
});

class MacroIndicatorNotifier extends AsyncNotifier<void> {
  @override
  Future<void> build() async {}

  Future<void> add(String name, int weight) async {
    final client = ref.read(supabaseClientProvider);
    final user = client.auth.currentUser;
    if (user == null) return;
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      await client.from('macro_indicators').insert({
        'user_id': user.id,
        'name': name.trim(),
        'weight': weight,
      });
      ref.invalidate(macroIndicatorsProvider);
    });
  }

  Future<void> edit(String id, String name, int weight) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      await ref.read(supabaseClientProvider).from('macro_indicators').update({
        'name': name.trim(),
        'weight': weight,
      }).eq('id', id);
      ref.invalidate(macroIndicatorsProvider);
    });
  }

  Future<void> delete(String id) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      await ref
          .read(supabaseClientProvider)
          .from('macro_indicators')
          .delete()
          .eq('id', id);
      ref.invalidate(macroIndicatorsProvider);
    });
  }
}

final macroIndicatorNotifierProvider =
    AsyncNotifierProvider<MacroIndicatorNotifier, void>(
        MacroIndicatorNotifier.new);
