// Test script for SEC Filing Data API connection.
// Usage:
//   dart run scripts/test_sec.dart <SEC_API_KEY> [TICKER]
//
// Examples:
//   dart run scripts/test_sec.dart sk_live_abc123
//   dart run scripts/test_sec.dart sk_live_abc123 TSLA

import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

const baseUrl = 'https://api.secfilingdata.com';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    print('Usage: dart run scripts/test_sec.dart <SEC_API_KEY> [TICKER]');
    exit(1);
  }

  final apiKey = args[0];
  final ticker = args.length > 1 ? args[1] : 'AAPL';

  print('Testing SEC connection...');
  print('  Endpoint : $baseUrl/live-query-api');
  print('  Ticker   : $ticker');
  print('');

  final client = http.Client();

  try {
    // --- Test 1: ticker filings ---
    print('[1] getFilingsForTicker($ticker)');
    final body = jsonEncode({
      'query': {
        'query_string': {
          'query': 'ticker:$ticker AND formType:("10-K" OR "10-Q" OR "8-K" OR "4")',
        },
      },
      'from': '0',
      'size': '5',
      'sort': [
        {'filedAt': {'order': 'desc'}},
      ],
    });

    final res = await client.post(
      Uri.parse('$baseUrl/live-query-api'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': apiKey,
      },
      body: body,
    );

    print('    Status : ${res.statusCode}');

    if (res.statusCode == 200) {
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      final total = json['total'];
      final filings = (json['filings'] as List?) ?? [];
      print('    Total  : $total');
      print('    Got    : ${filings.length} filings');
      for (final f in filings) {
        final date = f['filedAt']?.toString().split('T').first ?? '?';
        print('    - [${f['formType']}] ${f['companyName']} ($date)');
      }
    } else {
      print('    Error  : ${res.body}');
    }

    // --- Test 2: recent 8-K events ---
    print('');
    print('[2] getRecentEvents (8-K feed)');
    final body2 = jsonEncode({
      'query': {
        'query_string': {'query': 'formType:"8-K"'},
      },
      'from': '0',
      'size': '3',
      'sort': [
        {'filedAt': {'order': 'desc'}},
      ],
    });

    final res2 = await client.post(
      Uri.parse('$baseUrl/live-query-api'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': apiKey,
      },
      body: body2,
    );

    print('    Status : ${res2.statusCode}');

    if (res2.statusCode == 200) {
      final json2 = jsonDecode(res2.body) as Map<String, dynamic>;
      final filings2 = (json2['filings'] as List?) ?? [];
      print('    Got    : ${filings2.length} recent 8-K filings');
      for (final f in filings2) {
        final date = f['filedAt']?.toString().split('T').first ?? '?';
        print('    - ${f['companyName']} ($date)');
      }
    } else {
      print('    Error  : ${res2.body}');
    }

    print('');
    print('Done.');
  } finally {
    client.close();
  }
}
