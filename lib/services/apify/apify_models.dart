class ApifyRun {
  final String id;
  final String actId;
  final String status;
  final String? defaultDatasetId;
  final DateTime? startedAt;
  final DateTime? finishedAt;

  const ApifyRun({
    required this.id,
    required this.actId,
    required this.status,
    this.defaultDatasetId,
    this.startedAt,
    this.finishedAt,
  });

  factory ApifyRun.fromJson(Map<String, dynamic> j) {
    final data = j['data'] as Map<String, dynamic>? ?? j;
    return ApifyRun(
      id: data['id']?.toString() ?? '',
      actId: data['actId']?.toString() ?? '',
      status: data['status']?.toString() ?? '',
      defaultDatasetId: data['defaultDatasetId']?.toString(),
      startedAt: data['startedAt'] != null
          ? DateTime.tryParse(data['startedAt'].toString())
          : null,
      finishedAt: data['finishedAt'] != null
          ? DateTime.tryParse(data['finishedAt'].toString())
          : null,
    );
  }

  bool get isSucceeded => status == 'SUCCEEDED';
  bool get isRunning => status == 'RUNNING';
  bool get isFailed => status == 'FAILED';
}

class ApifyDatasetInfo {
  final String id;
  final int itemCount;
  final String name;

  const ApifyDatasetInfo({
    required this.id,
    required this.itemCount,
    required this.name,
  });

  factory ApifyDatasetInfo.fromJson(Map<String, dynamic> j) {
    final data = j['data'] as Map<String, dynamic>? ?? j;
    return ApifyDatasetInfo(
      id: data['id']?.toString() ?? '',
      itemCount: int.tryParse(data['itemCount']?.toString() ?? '0') ?? 0,
      name: data['name']?.toString() ?? '',
    );
  }
}

// Known Apify actor IDs for financial/economic scraping
class ApifyActors {
  // News & sentiment
  static const String googleNews = 'lhotanova~google-news-scraper';
  static const String twitterScraper = 'quacker~twitter-scraper';
  static const String redditScraper = 'trudax~reddit-scraper';

  // Financial data
  static const String yahooFinance = 'mscraper~yahoo-finance-scraper';
  static const String seekingAlpha = 'curious_coder~seeking-alpha-scraper';
}
