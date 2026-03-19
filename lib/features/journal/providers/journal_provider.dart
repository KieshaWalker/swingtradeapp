import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../auth/providers/auth_provider.dart';
import '../models/journal_entry.dart';

final journalProvider = FutureProvider<List<JournalEntry>>((ref) async {
  final client = ref.watch(supabaseClientProvider);
  final user = client.auth.currentUser;
  if (user == null) return [];

  final response = await client
      .from('journal_entries')
      .select()
      .eq('user_id', user.id)
      .order('created_at', ascending: false);

  return (response as List).map((e) => JournalEntry.fromJson(e)).toList();
});

class JournalNotifier extends AsyncNotifier<void> {
  SupabaseClient get _client => ref.read(supabaseClientProvider);

  @override
  Future<void> build() async {}

  Future<void> addEntry(JournalEntry entry) async {
    final user = _client.auth.currentUser;
    if (user == null) return;
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      await _client.from('journal_entries').insert({
        ...entry.toJson(),
        'user_id': user.id,
      });
      ref.invalidate(journalProvider);
    });
  }

  Future<void> deleteEntry(String id) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      await _client.from('journal_entries').delete().eq('id', id);
      ref.invalidate(journalProvider);
    });
  }
}

final journalNotifierProvider =
    AsyncNotifierProvider<JournalNotifier, void>(JournalNotifier.new);
