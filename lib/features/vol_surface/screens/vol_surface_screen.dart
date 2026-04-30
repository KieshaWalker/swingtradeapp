// =============================================================================
// vol_surface/screens/vol_surface_screen.dart
// =============================================================================
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme.dart';
import '../../../core/widgets/app_menu_button.dart';
import '../models/vol_surface_models.dart';
import '../providers/vol_surface_provider.dart';
import '../services/vol_surface_repository.dart';
import '../widgets/vol_heatmap.dart';
import '../widgets/vol_smile_chart.dart';
import '../widgets/vol_surface_guide.dart';
import '../widgets/vol_surface_interpretation.dart';

// ── IV mode options ────────────────────────────────────────────────────────────
const _ivModes = [
  ('otm', 'OTM'),
  ('call', 'Call'),
  ('put', 'Put'),
  ('avg', 'Avg'),
];

class VolSurfaceScreen extends ConsumerStatefulWidget {
  /// When non-null the screen is scoped to a single ticker (pushed from
  /// TickerProfileScreen). The sidebar is hidden and only that ticker's
  /// snapshots are shown. When null the global multi-ticker view is shown.
  final String? symbol;

  const VolSurfaceScreen({super.key, this.symbol});

  @override
  ConsumerState<VolSurfaceScreen> createState() => _VolSurfaceScreenState();
}

class _VolSurfaceScreenState extends ConsumerState<VolSurfaceScreen>
    with SingleTickerProviderStateMixin {
  String _ivMode = 'otm';
  VolSnapshot? _activeSnap;
  VolSnapshot? _baseSnap;
  bool _pointsLoading = false;
  late final TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _deleteSnap(VolSnapshot s) async {
    await ref.read(volSurfaceProvider.notifier).delete(s);
    if (_activeSnap?.ticker == s.ticker &&
        _activeSnap?.obsDateStr == s.obsDateStr) {
      setState(() => _activeSnap = null);
    }
  }

  Future<void> _selectSnap(VolSnapshot s) async {
    setState(() {
      _activeSnap = s;
      _pointsLoading = s.points.isEmpty && s.id != null;
    });
    if (s.points.isEmpty && s.id != null) {
      try {
        final pts = await VolSurfaceRepository(
          Supabase.instance.client,
        ).loadPoints(s.id!);
        if (!mounted) return;
        setState(() {
          _activeSnap = VolSnapshot(
            id: s.id,
            ticker: s.ticker,
            obsDate: s.obsDate,
            spotPrice: s.spotPrice,
            points: pts,
            parsedAt: s.parsedAt,
          );
          _pointsLoading = false;
        });
      } catch (_) {
        if (mounted) setState(() => _pointsLoading = false);
      }
    }
  }

  // ── Build ───────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final snapsAsync = ref.watch(volSurfaceProvider);
    final allSnaps = snapsAsync.valueOrNull ?? [];

    // When scoped to a ticker, only show that ticker's snapshots.
    final snaps = widget.symbol != null
        ? allSnaps
            .where((s) => s.ticker == widget.symbol!.toUpperCase())
            .toList()
        : allSnaps;

    // Auto-select the most recent snapshot on first data load.
    if (_activeSnap == null && snaps.isNotEmpty) {
      final latest =
          snaps.reduce((a, b) => a.obsDate.isAfter(b.obsDate) ? a : b);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _selectSnap(latest);
      });
    }

    final isTicker = widget.symbol != null;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(isTicker ? '${widget.symbol!.toUpperCase()} Vol Surface' : 'Vol Surface'),
            if (_activeSnap != null)
              Text(
                isTicker
                    ? _activeSnap!.obsDateStr
                    : '${_activeSnap!.ticker} · ${_activeSnap!.obsDateStr}',
                style: const TextStyle(
                    color: AppTheme.neutralColor,
                    fontSize: 11,
                    fontWeight: FontWeight.w400),
              ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded, size: 20),
            tooltip: 'Refresh datasets',
            onPressed: () => ref.invalidate(volSurfaceProvider),
          ),
          IconButton(
            icon: const Icon(Icons.help_outline_rounded, size: 20),
            tooltip: 'How to read this',
            onPressed: () => showVolSurfaceGuide(context, _tabs.index),
          ),
          if (!isTicker) const AppMenuButton(),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          // When scoped to a ticker, always skip the multi-ticker sidebar.
          final showSidebar = !isTicker && constraints.maxWidth < 400;
          if (showSidebar) {
            return Row(children: [
              _Sidebar(
                snaps:        snaps,
                activeSnap:   _activeSnap,
                onSelectSnap: _selectSnap,
                onDeleteSnap: _deleteSnap,
              ),
              Expanded(
                child: _MainPanel(
                  tabs:               _tabs,
                  ivMode:             _ivMode,
                  onIvModeChanged:    (m) => setState(() => _ivMode = m),
                  snaps:              snaps,
                  activeSnap:         _activeSnap,
                  baseSnap:           _baseSnap,
                  onActiveSnapChanged: _selectSnap,
                  onBaseSnapChanged:   (s) => setState(() => _baseSnap = s),
                  loading:            snapsAsync.isLoading || _pointsLoading,
                ),
              ),
            ]);
          }
          return _NarrowLayout(
            snaps:            snaps,
            activeSnap:       _activeSnap,
            onSelectSnap:     _selectSnap,
            onDeleteSnap:     _deleteSnap,
            tabs:             _tabs,
            ivMode:           _ivMode,
            onIvModeChanged:  (m) => setState(() => _ivMode = m),
            baseSnap:         _baseSnap,
            onBaseSnapChanged:(s) => setState(() => _baseSnap = s),
            loading:          snapsAsync.isLoading || _pointsLoading,
          );
        },
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Sidebar — ticker search + dataset list
// ═══════════════════════════════════════════════════════════════════════════════
class _Sidebar extends StatefulWidget {
  final List<VolSnapshot>          snaps;
  final VolSnapshot?               activeSnap;
  final ValueChanged<VolSnapshot>  onSelectSnap;
  final ValueChanged<VolSnapshot>  onDeleteSnap;

  const _Sidebar({
    required this.snaps,
    required this.activeSnap,
    required this.onSelectSnap,
    required this.onDeleteSnap,
  });

  @override
  State<_Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<_Sidebar> {
  final _searchCtrl = TextEditingController();
  String _filter = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filter.isEmpty
        ? widget.snaps
        : widget.snaps
            .where((s) =>
                s.ticker.toUpperCase().contains(_filter.toUpperCase()))
            .toList();

    return SizedBox(
      width: 264,
      child: Container(
        decoration: const BoxDecoration(
          color: Color(0xFF111827),
          border: Border(right: BorderSide(color: Color(0xFF1f2937))),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Header ──
            const Padding(
              padding: EdgeInsets.fromLTRB(14, 14, 14, 10),
              child: Text(
                'DATASETS',
                style: TextStyle(
                    fontSize:    10,
                    fontWeight:  FontWeight.w700,
                    letterSpacing: 1.2,
                    color:       Color(0xFF6b7280),
                    fontFamily:  'monospace'),
              ),
            ),
            // ── Ticker search ──
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
              child: TextField(
                controller: _searchCtrl,
                onChanged: (v) => setState(() => _filter = v),
                style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFFd1d5db),
                    fontFamily: 'monospace'),
                decoration: InputDecoration(
                  hintText: 'Search ticker…',
                  hintStyle: const TextStyle(
                      color: Color(0xFF4b5563), fontSize: 12),
                  prefixIcon: const Icon(Icons.search_rounded,
                      size: 15, color: Color(0xFF6b7280)),
                  suffixIcon: _filter.isNotEmpty
                      ? GestureDetector(
                          onTap: () {
                            _searchCtrl.clear();
                            setState(() => _filter = '');
                          },
                          child: const Icon(Icons.close_rounded,
                              size: 14, color: Color(0xFF6b7280)),
                        )
                      : null,
                  filled: true,
                  fillColor: const Color(0xFF0d1117),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: const BorderSide(color: Color(0xFF374151)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: const BorderSide(color: Color(0xFF374151)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: const BorderSide(color: Color(0xFF3b82f6)),
                  ),
                  isDense: true,
                ),
              ),
            ),
            const Divider(color: Color(0xFF1f2937), height: 1),
            // ── Dataset list ──
            Expanded(
              child: filtered.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(14),
                      child: Text(
                        _filter.isEmpty
                            ? 'No datasets yet.\n\nOpen an options chain to auto-ingest a vol surface.'
                            : 'No tickers match "$_filter".',
                        style: const TextStyle(
                            color:      Color(0xFF4b5563),
                            fontSize:   11,
                            fontStyle:  FontStyle.italic,
                            height:     1.6),
                      ),
                    )
                  : _GroupedDatasetList(
                      snaps:        filtered,
                      activeSnap:   widget.activeSnap,
                      onSelectSnap: widget.onSelectSnap,
                      onDeleteSnap: widget.onDeleteSnap,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Dataset tile
// ═══════════════════════════════════════════════════════════════════════════════
class _DatasetTile extends StatelessWidget {
  final VolSnapshot snap;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _DatasetTile({
    required this.snap,
    required this.active,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: active ? const Color(0x183b82f6) : Colors.transparent,
          border: Border.all(
            color: active
                ? const Color(0x593b82f6)
                : const Color(0xFF1f2937),
          ),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  snap.obsDateStr,
                  style: const TextStyle(
                      color:      Color(0xFFf9fafb),
                      fontSize:   12,
                      fontWeight: FontWeight.w600,
                      fontFamily: 'monospace'),
                ),
                const SizedBox(height: 2),
                Text(
                  snap.ticker +
                  (snap.points.isNotEmpty ? ' · ${snap.points.length} rows' : '') +
                  (snap.spotPrice != null ? ' · \$${snap.spotPrice!.toStringAsFixed(2)}' : ''),
                  style: const TextStyle(
                      color:     Color(0xFF6b7280),
                      fontSize:  10,
                      fontFamily: 'monospace'),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded, size: 14),
            color: const Color(0xFF6b7280),
            onPressed: onDelete,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
          ),
        ]),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Grouped dataset list — collapsible ticker sections, clickable headers
// ═══════════════════════════════════════════════════════════════════════════════
class _GroupedDatasetList extends ConsumerStatefulWidget {
  final List<VolSnapshot>          snaps;
  final VolSnapshot?               activeSnap;
  final ValueChanged<VolSnapshot>  onSelectSnap;
  final ValueChanged<VolSnapshot>  onDeleteSnap;
  final ScrollController?          scrollController;

  const _GroupedDatasetList({
    required this.snaps,
    required this.activeSnap,
    required this.onSelectSnap,
    required this.onDeleteSnap,
    this.scrollController,
  });

  @override
  ConsumerState<_GroupedDatasetList> createState() =>
      _GroupedDatasetListState();
}

class _GroupedDatasetListState extends ConsumerState<_GroupedDatasetList> {
  final Set<String> _collapsed = {};

  @override
  Widget build(BuildContext context) {
    final Map<String, List<VolSnapshot>> grouped = {};
    for (final s in widget.snaps) {
      grouped.putIfAbsent(s.ticker, () => []).add(s);
    }
    for (final v in grouped.values) {
      v.sort((a, b) => b.obsDate.compareTo(a.obsDate));
    }

    return ListView(
      controller: widget.scrollController,
      padding: const EdgeInsets.only(bottom: 8),
      children: [
        for (final ticker in grouped.keys) ...[
          _TickerHeader(
            ticker:    ticker,
            count:     grouped[ticker]!.length,
            collapsed: _collapsed.contains(ticker),
            isActive:  widget.activeSnap?.ticker == ticker,
            onTap: () => widget.onSelectSnap(grouped[ticker]!.first),
            onToggle: () => setState(() {
              if (_collapsed.contains(ticker)) {
                _collapsed.remove(ticker);
              } else {
                _collapsed.add(ticker);
              }
            }),
            onDeleteAll: () => _confirmDeleteTicker(context, ticker),
          ),
          if (!_collapsed.contains(ticker))
            for (final s in grouped[ticker]!)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: _DatasetTile(
                  snap:     s,
                  active:   widget.activeSnap?.id == s.id ||
                            (widget.activeSnap?.obsDateStr == s.obsDateStr &&
                             widget.activeSnap?.ticker == s.ticker),
                  onTap:    () => widget.onSelectSnap(s),
                  onDelete: () => widget.onDeleteSnap(s),
                ),
              ),
        ],
      ],
    );
  }

  Future<void> _confirmDeleteTicker(
      BuildContext context, String ticker) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1a1f2e),
        title: Text(
          'Delete all $ticker snapshots?',
          style: const TextStyle(color: Colors.white, fontSize: 15),
        ),
        content: Text(
          'This will permanently remove all '
          '${widget.snaps.where((s) => s.ticker == ticker).length} '
          'surfaces for $ticker.',
          style: const TextStyle(color: Colors.white60, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel',
                style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete All',
                style: TextStyle(color: Color(0xFFFF6B8A))),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      await ref.read(volSurfaceProvider.notifier).deleteByTicker(ticker);
    }
  }
}

class _TickerHeader extends StatelessWidget {
  final String ticker;
  final int    count;
  final bool   collapsed;
  final bool   isActive;
  final VoidCallback onTap;
  final VoidCallback onToggle;
  final VoidCallback onDeleteAll;

  const _TickerHeader({
    required this.ticker,
    required this.count,
    required this.collapsed,
    required this.isActive,
    required this.onTap,
    required this.onToggle,
    required this.onDeleteAll,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.fromLTRB(8, 8, 8, 2),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: isActive
              ? const Color(0x1A3b82f6)
              : const Color(0xFF0d1117),
          border: Border.all(
              color: isActive
                  ? const Color(0x553b82f6)
                  : const Color(0xFF1f2937)),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          children: [
            GestureDetector(
              onTap: onToggle,
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Icon(
                  collapsed
                      ? Icons.chevron_right_rounded
                      : Icons.expand_more_rounded,
                  size: 16,
                  color: const Color(0xFF4b5563),
                ),
              ),
            ),
            Text(
              ticker,
              style: TextStyle(
                color:        isActive
                    ? const Color(0xFF60a5fa)
                    : const Color(0xFF93c5fd),
                fontSize:     12,
                fontWeight:   FontWeight.w700,
                letterSpacing: 0.8,
                fontFamily:   'monospace',
              ),
            ),
            const SizedBox(width: 6),
            Text(
              '$count',
              style: const TextStyle(
                  color:     Color(0xFF4b5563),
                  fontSize:  10,
                  fontFamily: 'monospace'),
            ),
            const Spacer(),
            GestureDetector(
              onTap: onDeleteAll,
              behavior: HitTestBehavior.opaque,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                child: Icon(Icons.delete_outline_rounded,
                    size: 14, color: Color(0xFF4b5563)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Main panel (wide layout)
// ═══════════════════════════════════════════════════════════════════════════════
class _MainPanel extends StatelessWidget {
  final TabController           tabs;
  final String                  ivMode;
  final ValueChanged<String>    onIvModeChanged;
  final List<VolSnapshot>       snaps;
  final VolSnapshot?            activeSnap;
  final VolSnapshot?            baseSnap;
  final ValueChanged<VolSnapshot> onActiveSnapChanged;
  final ValueChanged<VolSnapshot> onBaseSnapChanged;
  final bool                    loading;

  const _MainPanel({
    required this.tabs,
    required this.ivMode,
    required this.onIvModeChanged,
    required this.snaps,
    required this.activeSnap,
    required this.baseSnap,
    required this.onActiveSnapChanged,
    required this.onBaseSnapChanged,
    required this.loading,
  });

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      _ControlsBar(
        tabs:               tabs,
        ivMode:             ivMode,
        onIvModeChanged:    onIvModeChanged,
        snaps:              snaps,
        activeSnap:         activeSnap,
        baseSnap:           baseSnap,
        onActiveSnapChanged: onActiveSnapChanged,
        onBaseSnapChanged:   onBaseSnapChanged,
      ),
      Expanded(child: _ChartArea(
        tabs:       tabs,
        activeSnap: activeSnap,
        baseSnap:   baseSnap,
        ivMode:     ivMode,
        loading:    loading,
      )),
      if (activeSnap != null)
        SizedBox(
          height: 220,
          child: VolSurfaceInterpretation(
            snap:   activeSnap!,
            ivMode: ivMode,
          ),
        ),
    ]);
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Controls bar
// ═══════════════════════════════════════════════════════════════════════════════
class _ControlsBar extends StatelessWidget {
  final TabController           tabs;
  final String                  ivMode;
  final ValueChanged<String>    onIvModeChanged;
  final List<VolSnapshot>       snaps;
  final VolSnapshot?            activeSnap;
  final VolSnapshot?            baseSnap;
  final ValueChanged<VolSnapshot> onActiveSnapChanged;
  final ValueChanged<VolSnapshot> onBaseSnapChanged;

  const _ControlsBar({
    required this.tabs,
    required this.ivMode,
    required this.onIvModeChanged,
    required this.snaps,
    required this.activeSnap,
    required this.baseSnap,
    required this.onActiveSnapChanged,
    required this.onBaseSnapChanged,
  });

  @override
  Widget build(BuildContext context) {
    final selectedTicker = baseSnap?.ticker ?? activeSnap?.ticker;

    return AnimatedBuilder(
      animation: tabs,
      builder: (context2, child) => Container(
        decoration: const BoxDecoration(
          color: Color(0xFF111827),
          border: Border(bottom: BorderSide(color: Color(0xFF1f2937))),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Wrap(
          spacing: 14,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _SegmentedControl(
              options: const [
                ('heatmap', 'Heatmap'),
                ('smile', 'Smile'),
                ('diff', 'Diff'),
              ],
              selected: ['heatmap', 'smile', 'diff'][tabs.index],
              onSelected: (v) =>
                  tabs.animateTo(['heatmap', 'smile', 'diff'].indexOf(v)),
            ),
            _SegmentedControl(
              options: _ivModes,
              selected: ivMode,
              onSelected: onIvModeChanged,
            ),
            if (tabs.index == 2 && snaps.isNotEmpty) ...[
              _SnapSelect(
                label: 'Base',
                snaps: selectedTicker != null
                    ? snaps.where((s) => s.ticker == selectedTicker).toList()
                    : snaps,
                selected: baseSnap,
                onChanged: onBaseSnapChanged,
              ),
              _SnapSelect(
                label: 'Compare',
                snaps: selectedTicker != null
                    ? snaps.where((s) => s.ticker == selectedTicker).toList()
                    : snaps,
                selected: activeSnap,
                onChanged: onActiveSnapChanged,
              ),
            ] else if (tabs.index != 2 && snaps.isNotEmpty)
              _SnapSelect(
                label: 'Date',
                snaps: activeSnap != null
                    ? snaps
                        .where((s) => s.ticker == activeSnap!.ticker)
                        .toList()
                    : snaps,
                selected: activeSnap,
                onChanged: onActiveSnapChanged,
              ),
          ],
        ),
      ),
    );
  }
}

class _SegmentedControl extends StatelessWidget {
  final List<(String, String)> options;
  final String                 selected;
  final ValueChanged<String>   onSelected;

  const _SegmentedControl({
    required this.options,
    required this.selected,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xFF374151)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < options.length; i++)
            GestureDetector(
              onTap: () => onSelected(options[i].$1),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: selected == options[i].$1
                      ? const Color(0xFF3b82f6)
                      : Colors.transparent,
                  borderRadius: BorderRadius.horizontal(
                    left:  i == 0 ? const Radius.circular(5) : Radius.zero,
                    right: i == options.length - 1
                        ? const Radius.circular(5)
                        : Radius.zero,
                  ),
                  border: i > 0
                      ? const Border(
                          left: BorderSide(color: Color(0xFF374151)))
                      : null,
                ),
                child: Text(
                  options[i].$2,
                  style: TextStyle(
                    fontSize:   11,
                    fontWeight: FontWeight.w600,
                    fontFamily: 'monospace',
                    color: selected == options[i].$1
                        ? Colors.white
                        : const Color(0xFF9ca3af),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SnapSelect extends StatelessWidget {
  final String                 label;
  final List<VolSnapshot>      snaps;
  final VolSnapshot?           selected;
  final ValueChanged<VolSnapshot> onChanged;

  const _SnapSelect({
    required this.label,
    required this.snaps,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Text('$label ',
          style: const TextStyle(
              fontSize:     10,
              fontWeight:   FontWeight.w700,
              letterSpacing: 0.8,
              color:        Color(0xFF6b7280),
              fontFamily:   'monospace')),
      DropdownButton<VolSnapshot>(
        value: selected == null
            ? null
            : snaps
                .where((s) =>
                    s.ticker == selected!.ticker &&
                    s.obsDateStr == selected!.obsDateStr)
                .firstOrNull,
        hint: const Text('—',
            style: TextStyle(
                color:     Color(0xFF6b7280),
                fontSize:  11,
                fontFamily: 'monospace')),
        items: snaps
            .map((s) => DropdownMenuItem(
                  value: s,
                  child: Text(s.obsDateStr,
                      style: const TextStyle(
                          fontSize: 11, fontFamily: 'monospace')),
                ))
            .toList(),
        onChanged: (s) {
          if (s != null) onChanged(s);
        },
        dropdownColor: const Color(0xFF111827),
        style: const TextStyle(
            color:     Color(0xFFd1d5db),
            fontSize:  11,
            fontFamily: 'monospace'),
        underline: const SizedBox.shrink(),
        isDense: true,
      ),
    ]);
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Chart area
// ═══════════════════════════════════════════════════════════════════════════════
class _ChartArea extends StatelessWidget {
  final TabController tabs;
  final VolSnapshot?  activeSnap;
  final VolSnapshot?  baseSnap;
  final String        ivMode;
  final bool          loading;

  const _ChartArea({
    required this.tabs,
    required this.activeSnap,
    required this.baseSnap,
    required this.ivMode,
    required this.loading,
  });

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Center(child: CircularProgressIndicator());
    }
    return TabBarView(
      controller: tabs,
      physics: const NeverScrollableScrollPhysics(),
      children: [
        activeSnap != null
            ? VolHeatmap(
                points:    activeSnap!.points,
                spotPrice: activeSnap!.spotPrice,
                ivMode:    ivMode,
              )
            : _empty('Select a ticker and date to view the surface'),
        activeSnap != null
            ? VolSmileChart(
                points:    activeSnap!.points,
                spotPrice: activeSnap!.spotPrice,
                ivMode:    ivMode,
              )
            : _empty('Select a ticker and date to view the smile'),
        (activeSnap != null && baseSnap != null)
            ? _DiffHeatmap(
                base:    baseSnap!,
                compare: activeSnap!,
                ivMode:  ivMode,
              )
            : _empty('Select Base and Compare datasets'),
      ],
    );
  }

  Widget _empty(String msg) => Center(
        child: Text(msg,
            style: const TextStyle(
                color:     Color(0xFF4b5563),
                fontSize:  13,
                fontFamily: 'monospace')),
      );
}

// ── Diff heatmap — computes IV(compare) − IV(base) ────────────────────────────
class _DiffHeatmap extends StatelessWidget {
  final VolSnapshot base;
  final VolSnapshot compare;
  final String      ivMode;

  const _DiffHeatmap({
    required this.base,
    required this.compare,
    required this.ivMode,
  });

  @override
  Widget build(BuildContext context) {
    Map<(int, double), double?> ivMap(VolSnapshot s) {
      final m = <(int, double), double?>{};
      for (final p in s.points) {
        m[(p.dte, p.strike)] = p.iv(ivMode, s.spotPrice);
      }
      return m;
    }

    final baseMap = ivMap(base);
    final cmpMap  = ivMap(compare);

    final diffPoints = <VolPoint>[];
    for (final entry in cmpMap.entries) {
      final bv = baseMap[entry.key];
      final cv = entry.value;
      if (bv != null && cv != null) {
        diffPoints.add(VolPoint(
          strike: entry.key.$2,
          dte:    entry.key.$1,
          callIv: cv - bv,
        ));
      }
    }

    if (diffPoints.isEmpty) {
      return const Center(
          child: Text('No overlapping data between the two datasets',
              style: TextStyle(
                  color:     Color(0xFF4b5563),
                  fontSize:  13,
                  fontFamily: 'monospace')));
    }

    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: Row(children: [
          Text('${compare.obsDateStr} − ${base.obsDateStr}',
              style: const TextStyle(
                  color:     Color(0xFF9ca3af),
                  fontSize:  11,
                  fontFamily: 'monospace')),
          const SizedBox(width: 12),
          const Text('Red = IV rose  ·  Blue = IV fell',
              style: TextStyle(
                  color:      Color(0xFF6b7280),
                  fontSize:   10,
                  fontStyle:  FontStyle.italic,
                  fontFamily: 'monospace')),
        ]),
      ),
      Expanded(
        child: VolHeatmap(
          points:    diffPoints,
          spotPrice: compare.spotPrice,
          ivMode:    'call',
        ),
      ),
    ]);
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Narrow layout — full-screen chart with FAB to open dataset picker
// ═══════════════════════════════════════════════════════════════════════════════
class _NarrowLayout extends StatefulWidget {
  final List<VolSnapshot>          snaps;
  final VolSnapshot?               activeSnap;
  final ValueChanged<VolSnapshot>  onSelectSnap;
  final ValueChanged<VolSnapshot>  onDeleteSnap;
  final TabController              tabs;
  final String                     ivMode;
  final ValueChanged<String>       onIvModeChanged;
  final VolSnapshot?               baseSnap;
  final ValueChanged<VolSnapshot>  onBaseSnapChanged;
  final bool                       loading;

  const _NarrowLayout({
    required this.snaps,
    required this.activeSnap,
    required this.onSelectSnap,
    required this.onDeleteSnap,
    required this.tabs,
    required this.ivMode,
    required this.onIvModeChanged,
    required this.baseSnap,
    required this.onBaseSnapChanged,
    required this.loading,
  });

  @override
  State<_NarrowLayout> createState() => _NarrowLayoutState();
}

class _NarrowLayoutState extends State<_NarrowLayout> {
  double _interpHeight = 220;
  static const double _interpMin = 80;
  static const double _interpMax = 440;

  void _showDatasetSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF111827),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        minChildSize:     0.4,
        maxChildSize:     0.92,
        builder: (ctx, scrollController) => _DatasetSheetContent(
          snaps:        widget.snaps,
          activeSnap:   widget.activeSnap,
          onSelectSnap: (s) {
            widget.onSelectSnap(s);
            Navigator.pop(context);
          },
          onDeleteSnap: widget.onDeleteSnap,
          scrollController: scrollController,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Column(children: [
          _ControlsBar(
            tabs:               widget.tabs,
            ivMode:             widget.ivMode,
            onIvModeChanged:    widget.onIvModeChanged,
            snaps:              widget.snaps,
            activeSnap:         widget.activeSnap,
            baseSnap:           widget.baseSnap,
            onActiveSnapChanged: widget.onSelectSnap,
            onBaseSnapChanged:   widget.onBaseSnapChanged,
          ),
          Expanded(child: _ChartArea(
            tabs:       widget.tabs,
            activeSnap: widget.activeSnap,
            baseSnap:   widget.baseSnap,
            ivMode:     widget.ivMode,
            loading:    widget.loading,
          )),
          if (widget.activeSnap != null) ...[
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onVerticalDragUpdate: (d) => setState(() {
                _interpHeight = (_interpHeight - d.delta.dy)
                    .clamp(_interpMin, _interpMax);
              }),
              child: Container(
                height: 16,
                color: const Color(0xFF111827),
                child: Center(
                  child: Container(
                    width: 36, height: 4,
                    decoration: BoxDecoration(
                      color: const Color(0xFF374151),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
            ),
            SizedBox(
              height: _interpHeight,
              child: VolSurfaceInterpretation(
                snap:   widget.activeSnap!,
                ivMode: widget.ivMode,
              ),
            ),
          ],
        ]),
        Positioned(
          bottom: widget.activeSnap != null ? _interpHeight + 16 + 16 : 16,
          right:  16,
          child: FloatingActionButton.extended(
            onPressed: () => _showDatasetSheet(context),
            backgroundColor: const Color(0xFF3b82f6),
            label: const Text('Datasets',
                style: TextStyle(fontFamily: 'monospace')),
            icon: const Icon(Icons.dataset_rounded),
          ),
        ),
      ],
    );
  }
}

// Bottom sheet content for narrow layout
class _DatasetSheetContent extends StatefulWidget {
  final List<VolSnapshot>          snaps;
  final VolSnapshot?               activeSnap;
  final ValueChanged<VolSnapshot>  onSelectSnap;
  final ValueChanged<VolSnapshot>  onDeleteSnap;
  final ScrollController           scrollController;

  const _DatasetSheetContent({
    required this.snaps,
    required this.activeSnap,
    required this.onSelectSnap,
    required this.onDeleteSnap,
    required this.scrollController,
  });

  @override
  State<_DatasetSheetContent> createState() => _DatasetSheetContentState();
}

class _DatasetSheetContentState extends State<_DatasetSheetContent> {
  final _searchCtrl = TextEditingController();
  String _filter = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filter.isEmpty
        ? widget.snaps
        : widget.snaps
            .where((s) =>
                s.ticker.toUpperCase().contains(_filter.toUpperCase()))
            .toList();

    return Column(children: [
      // Drag handle
      
      Center(
        child: Container(
          margin: const EdgeInsets.only(top: 10, bottom: 12),
          width: 36, height: 4,
          decoration: BoxDecoration(
            color: const Color(0xFF374151),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
      // Header
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 10),
        child: Row(children: [
          Text('SELECT DATASET',
              style: TextStyle(
                  fontSize:    10,
                  fontWeight:  FontWeight.w700,
                  letterSpacing: 1.2,
                  color:       Color(0xFF6b7280),
                  fontFamily:  'monospace')),
        ]),
      ),
      // Search
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
        child: TextField(
          controller: _searchCtrl,
          autofocus: true,
          onChanged: (v) => setState(() => _filter = v),
          style: const TextStyle(
              fontSize: 13, color: Color(0xFFd1d5db)),
          decoration: InputDecoration(
            hintText: 'Search ticker…',
            hintStyle: const TextStyle(color: Color(0xFF4b5563)),
            prefixIcon: const Icon(Icons.search_rounded,
                size: 18, color: Color(0xFF6b7280)),
            suffixIcon: _filter.isNotEmpty
                ? GestureDetector(
                    onTap: () {
                      _searchCtrl.clear();
                      setState(() => _filter = '');
                    },
                    child: const Icon(Icons.close_rounded,
                        size: 16, color: Color(0xFF6b7280)),
                  )
                : null,
            filled: true,
            fillColor: const Color(0xFF0d1117),
            contentPadding: const EdgeInsets.symmetric(vertical: 10),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: Color(0xFF374151)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: Color(0xFF374151)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: Color(0xFF3b82f6)),
            ),
          ),
        ),
      ),
      const Divider(color: Color(0xFF1f2937), height: 1),
      // List
      Expanded(
        child: filtered.isEmpty
            ? Center(
                child: Text(
                  _filter.isEmpty
                      ? 'No datasets yet.\nOpen an options chain to auto-ingest.'
                      : 'No tickers match "$_filter".',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color:     Color(0xFF4b5563),
                      fontSize:  13,
                      height:    1.6),
                ),
              )
            : _GroupedDatasetList(
                snaps:           filtered,
                activeSnap:      widget.activeSnap,
                onSelectSnap:    widget.onSelectSnap,
                onDeleteSnap:    widget.onDeleteSnap,
                scrollController: widget.scrollController,
              ),
      ),
    ]);
  }
}
