// =============================================================================
// services/macro/macro_score_provider.dart
// =============================================================================
// This provider fetches macro score data from the Python backend.
// Backend route:
//   POST /macro/score -> api/routers/macro.py
//
// Update this provider if the macro score contract changes or if the
// Flutter app begins to use a different request/response shape.
// =============================================================================
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'macro_score_model.dart';
import '../python_api/python_api_client.dart';

final macroScoreProvider = FutureProvider<MacroScore>((ref) async {
  final raw = await PythonApiClient.macroScore();
  return MacroScore.fromJson(raw);
});
