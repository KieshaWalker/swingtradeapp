// =============================================================================
// services/macro/macro_score_provider.dart
// =============================================================================
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'macro_score_model.dart';
import '../python_api/python_api_client.dart';

final macroScoreProvider = FutureProvider<MacroScore>((ref) async {
  final raw = await PythonApiClient.macroScore();
  return MacroScore.fromJson(raw);
});
