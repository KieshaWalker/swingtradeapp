// =============================================================================
// features/greek_grid/services/greek_grid_ingester.dart
// =============================================================================
// Fire-and-forget helper: sends a wide Schwab chain to the Python API which
// aggregates it into GreekGridPoints and persists to Supabase.
// =============================================================================

import '../../../services/schwab/schwab_service.dart';
import '../../../services/python_api/python_api_client.dart';

Future<void> autoIngestGreekGrid(String symbol) async {
  try {
    final chain = await SchwabService().getOptionsChain(
      symbol,
      contractType: 'ALL',
      strikeCount:  40,
    );
    if (chain == null || chain.expirations.isEmpty) return;

    await PythonApiClient.greekGridIngest(
      chain:  chain.rawJson,
      ticker: symbol,
    );
  } catch (_) {
    // Never disrupt the options chain UI.
  }
}
