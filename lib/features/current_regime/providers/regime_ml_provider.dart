// =============================================================================
// features/current_regime/providers/regime_ml_provider.dart
// =============================================================================
import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../services/python_api/python_api_client.dart';
import '../models/regime_ml_models.dart';

final regimeMlProvider = FutureProvider<RegimeMlAnalysis>((ref) async {
  final link  = ref.keepAlive();
  final timer = Timer(const Duration(minutes: 30), link.close);
  ref.onDispose(timer.cancel);
  final raw = await PythonApiClient.regimeMlAnalyze();
  return RegimeMlAnalysis.fromJson(raw);
});
