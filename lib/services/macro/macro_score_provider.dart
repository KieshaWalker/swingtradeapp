// =============================================================================
// services/macro/macro_score_provider.dart
// =============================================================================
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'macro_score_model.dart';
import 'macro_score_service.dart';

final macroScoreProvider = FutureProvider<MacroScore>((ref) async {
  final db = Supabase.instance.client;
  return MacroScoreService(db).computeScore();
});
