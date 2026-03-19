import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../core/theme.dart';
import '../../../services/sec/sec_models.dart';
import '../../../services/sec/sec_providers.dart';

class ResearchScreen extends ConsumerStatefulWidget {
  const ResearchScreen({super.key});

  @override
  ConsumerState<ResearchScreen> createState() => _ResearchScreenState();
}

class _ResearchScreenState extends ConsumerState<ResearchScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  final _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('SEC Research'),
        bottom: TabBar(
          controller: _tabs,
          indicatorColor: AppTheme.profitColor,
          labelColor: AppTheme.profitColor,
          unselectedLabelColor: AppTheme.neutralColor,
          tabs: const [
            Tab(text: 'Search Filings'),
            Tab(text: 'Recent 8-K Events'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _SearchTab(
            ctrl: _searchCtrl,
            query: _query,
            onChanged: (v) => setState(() => _query = v),
          ),
          const _RecentEventsTab(),
        ],
      ),
    );
  }
}

// ----------------------------------------------------------------
// Search tab
// ----------------------------------------------------------------
class _SearchTab extends ConsumerWidget {
  final TextEditingController ctrl;
  final String query;
  final ValueChanged<String> onChanged;

  const _SearchTab({
    required this.ctrl,
    required this.query,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final resultsAsync = ref.watch(secSearchProvider(query));

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: TextField(
            controller: ctrl,
            decoration: InputDecoration(
              labelText: 'Search SEC filings',
              hintText: 'e.g. AAPL 10-K, Tesla earnings, insider',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: query.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        ctrl.clear();
                        onChanged('');
                      },
                    )
                  : null,
            ),
            onChanged: onChanged,
          ),
        ),
        if (query.isEmpty)
          const Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.article_outlined,
                      size: 56, color: AppTheme.neutralColor),
                  SizedBox(height: 12),
                  Text(
                    'Search 18M+ SEC filings.\nTry a ticker, company name, or form type.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppTheme.neutralColor),
                  ),
                ],
              ),
            ),
          )
        else
          Expanded(
            child: resultsAsync.when(
              loading: () =>
                  const Center(child: CircularProgressIndicator()),
              error: (e, _) =>
                  Center(child: Text('Error: $e')),
              data: (filings) {
                if (filings.isEmpty) {
                  return const Center(
                    child: Text(
                      'No filings found.',
                      style: TextStyle(color: AppTheme.neutralColor),
                    ),
                  );
                }
                return ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  itemCount: filings.length,
                  separatorBuilder: (context, _) =>
                      const SizedBox(height: 8),
                  itemBuilder: (context, i) =>
                      _FilingCard(filing: filings[i]),
                );
              },
            ),
          ),
      ],
    );
  }
}

// ----------------------------------------------------------------
// Recent 8-K events tab
// ----------------------------------------------------------------
class _RecentEventsTab extends ConsumerWidget {
  const _RecentEventsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final eventsAsync = ref.watch(secRecentEventsProvider);

    return eventsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (filings) {
        if (filings.isEmpty) {
          return const Center(
            child: Text(
              'No recent events.',
              style: TextStyle(color: AppTheme.neutralColor),
            ),
          );
        }
        return RefreshIndicator(
          onRefresh: () => ref.refresh(secRecentEventsProvider.future),
          child: ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: filings.length,
            separatorBuilder: (context, _) => const SizedBox(height: 8),
            itemBuilder: (context, i) => _FilingCard(filing: filings[i]),
          ),
        );
      },
    );
  }
}

// ----------------------------------------------------------------
// Shared filing card
// ----------------------------------------------------------------
class _FilingCard extends StatelessWidget {
  final SecFiling filing;
  const _FilingCard({required this.filing});

  Color get _categoryColor => switch (filing.category) {
        'earnings' => const Color(0xFF58A6FF),
        'event' => const Color(0xFFE3B341),
        'insider' => AppTheme.profitColor,
        'holder' => const Color(0xFFD2A8FF),
        _ => AppTheme.neutralColor,
      };

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _openLink(filing.linkToHtml),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  // Form type badge
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: _categoryColor.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                          color: _categoryColor.withValues(alpha: 0.4)),
                    ),
                    child: Text(
                      filing.formType,
                      style: TextStyle(
                        color: _categoryColor,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (filing.ticker.isNotEmpty)
                    Text(
                      filing.ticker,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 14,
                      ),
                    ),
                  const Spacer(),
                  Text(
                    DateFormat('MMM d, yyyy').format(filing.filedAt),
                    style: const TextStyle(
                        color: AppTheme.neutralColor, fontSize: 12),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                filing.companyName,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              Text(
                filing.formLabel,
                style: const TextStyle(
                    color: AppTheme.neutralColor, fontSize: 13),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Icon(Icons.open_in_new,
                      size: 13, color: AppTheme.neutralColor),
                  const SizedBox(width: 4),
                  const Text(
                    'View on SEC EDGAR',
                    style: TextStyle(
                        color: AppTheme.neutralColor, fontSize: 12),
                  ),
                  if (filing.linkToXbrl != null) ...[
                    const SizedBox(width: 16),
                    GestureDetector(
                      onTap: () => _openLink(filing.linkToXbrl!),
                      child: const Text(
                        'XBRL',
                        style: TextStyle(
                            color: AppTheme.profitColor, fontSize: 12),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openLink(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }
}
