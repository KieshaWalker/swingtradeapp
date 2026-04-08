// =============================================================================
// services/sec/sec_models.dart — SEC filing data model
// =============================================================================
// Endpoint: https://api.sec-api.io?token={SEC_API_KEY}  (POST, Elasticsearch DSL)
// Auth: token= query param (NOT Authorization header)
// Response shape: { total: {value,relation}, filings: [ {...} ] }
//
// SecFiling
//   Endpoint fields used: accessionNo, cik, ticker, companyName, formType,
//                         linkToHtml, linkToXbrl, filedAt
//   Additional fields available but unused: companyNameLong, description,
//     linkToTxt, linkToFilingDetails, documentFormatFiles, periodOfReport,
//     entities, dataFiles
//
//   Getters:
//     formLabel — human-readable label shown in _SecFilingRow & _FilingCard
//                 e.g. "10-K  Annual Report", "Form 4  Insider Trade"
//     category  — drives badge color in _SecFilingRow & _FilingCard:
//                 'earnings' → blue   (10-K, 10-Q)
//                 'event'    → yellow (8-K)
//                 'insider'  → green  (Form 4)
//                 'holder'   → purple (SC 13G, SC 13D)
//
//   SecService methods → providers → widgets:
//     getFilingsForTicker()  → secFilingsForTickerProvider  → TradeDetailScreen (_SecFilingsSection)
//     searchFilings()        → secSearchProvider            → ResearchScreen (_SearchTab)
//     getRecentEvents()      → secRecentEventsProvider      → ResearchScreen (_RecentEventsTab)
//                         — _RecentEventsTab → _FilingCard
// =============================================================================
class SecFiling {
  final String accessionNo;
  final String cik;
  final String ticker;
  final String companyName;
  final String formType;
  final String linkToHtml;
  final String? linkToXbrl;
  final DateTime filedAt;

  const SecFiling({
    required this.accessionNo,
    required this.cik,
    required this.ticker,
    required this.companyName,
    required this.formType,
    required this.linkToHtml,
    this.linkToXbrl,
    required this.filedAt,
  });

  /// Human-readable label for the form type with context for traders
  String get formLabel => switch (formType) {
        '10-K' => '10-K  Annual Report',
        '10-Q' => '10-Q  Quarterly Report',
        '8-K' => '8-K  Current Report',
        '4' => 'Form 4  Insider Trade',
        'SC 13G' => 'SC 13G  Large Holder',
        'SC 13D' => 'SC 13D  Activist Holder',
        'S-1' => 'S-1  IPO Registration',
        'DEF 14A' => 'DEF 14A  Proxy Statement',
        _ => formType,
      };

  /// Color category for the form type
  String get category => switch (formType) {
        '10-K' || '10-Q' => 'earnings',
        '8-K' => 'event',
        '4' => 'insider',
        'SC 13G' || 'SC 13D' => 'holder',
        _ => 'other',
      };

  factory SecFiling.fromJson(Map<String, dynamic> json) {
    // Handle both API response formats
    final tickerValue = json['ticker'];
    String tickerStr = '';
    if (tickerValue is String) {
      tickerStr = tickerValue;
    } else if (tickerValue is Map) {
      tickerStr = tickerValue['ticker'] as String? ?? '';
    }

    return SecFiling(
      accessionNo: json['accessionNo'] as String? ??
          json['filing_id'] as String? ?? '',
      cik: json['cik'] as String? ?? json['cik_number'] as String? ?? '',
      ticker: tickerStr,
      companyName: json['companyName'] as String? ??
          json['company_name'] as String? ?? '',
      formType: json['formType'] as String? ??
          json['form_type'] as String? ?? '',
      linkToHtml: json['linkToHtml'] as String? ??
          json['link'] as String? ?? '',
      linkToXbrl: json['linkToXbrl'] as String?,
      filedAt: _parseDate(json['filedAt'] as String? ??
          json['filing_date'] as String? ?? ''),
    );
  }

  static DateTime _parseDate(String raw) {
    try {
      return DateTime.parse(raw);
    } catch (_) {
      return DateTime.now();
    }
  }
}
