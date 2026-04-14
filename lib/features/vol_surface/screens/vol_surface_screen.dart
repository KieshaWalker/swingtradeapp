// =============================================================================
// vol_surface/screens/vol_surface_screen.dart
// =============================================================================
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/widgets/app_menu_button.dart';
import '../models/vol_surface_models.dart';
import '../providers/vol_surface_provider.dart';
import '../services/vol_surface_parser.dart';
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
  const VolSurfaceScreen({super.key});

  @override
  ConsumerState<VolSurfaceScreen> createState() => _VolSurfaceScreenState();
}

class _VolSurfaceScreenState extends ConsumerState<VolSurfaceScreen>
    with SingleTickerProviderStateMixin {
  final _csvController = TextEditingController();
  DateTime _obsDate = DateTime.now();
  String _statusMsg = '';
  bool _isError = false;
  bool _parsing = false;
  String _ivMode = 'otm';
  VolSnapshot? _activeSnap;
  VolSnapshot? _baseSnap;
  late final TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _csvController.dispose();
    _tabs.dispose();
    super.dispose();
  }

  // ── Parse & Save ────────────────────────────────────────────────────────────
  Future<void> _parseAndSave() async {
    final csv = _csvController.text.trim();
    if (csv.isEmpty) {
      _setStatus('Paste CSV content first.', error: true);
      return;
    }
    setState(() {
      _parsing = true;
      _statusMsg = '';
      _isError = false;
    });
    try {
      final snap = VolSurfaceParser.parse(csv, _obsDate);
      await ref.read(volSurfaceProvider.notifier).save(snap);
      _csvController.clear();
      setState(() {
        _activeSnap = snap;
        _parsing = false;
      });
      _setStatus(
        '${snap.ticker} · ${snap.points.length} rows'
        '${snap.spotPrice != null ? ' · \$${snap.spotPrice!.toStringAsFixed(2)}' : ''}',
        error: false,
      );
    } catch (e) {
      setState(() => _parsing = false);
      _setStatus(e.toString(), error: true);
    }
  }

  void _setStatus(String msg, {required bool error}) =>
      setState(() {
        _statusMsg = msg;
        _isError = error;
      });

  String _fmtDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  // ── Pick date ───────────────────────────────────────────────────────────────
  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _obsDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) setState(() => _obsDate = picked);
  }

  // ── Build ───────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final snapsAsync = ref.watch(volSurfaceProvider);
    final snaps = snapsAsync.valueOrNull ?? [];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Vol Surface'),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline_rounded, size: 20),
            tooltip: 'How to read this',
            onPressed: () => showVolSurfaceGuide(context, _tabs.index),
          ),
          const AppMenuButton(),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth > 680;
          return wide
              ? Row(children: [
                  _Sidebar(
                    csvController: _csvController,
                    obsDate: _obsDate,
                    onPickDate: _pickDate,
                    statusMsg: _statusMsg,
                    isError: _isError,
                    parsing: _parsing,
                    onParse: _parseAndSave,
                    snaps: snaps,
                    activeSnap: _activeSnap,
                    onSelectSnap: (s) => setState(() => _activeSnap = s),
                    onDeleteSnap: (s) async {
                      await ref.read(volSurfaceProvider.notifier).delete(s);
                      if (_activeSnap?.ticker == s.ticker && _activeSnap?.obsDateStr == s.obsDateStr) {
                        setState(() => _activeSnap = null);
                      }
                    },
                    fmtDate: _fmtDate,
                  ),
                  Expanded(
                      child: _MainPanel(
                    tabs: _tabs,
                    ivMode: _ivMode,
                    onIvModeChanged: (m) => setState(() => _ivMode = m),
                    snaps: snaps,
                    activeSnap: _activeSnap,
                    baseSnap: _baseSnap,
                    onActiveSnapChanged: (s) => setState(() => _activeSnap = s),
                    onBaseSnapChanged: (s) => setState(() => _baseSnap = s),
                    loading: snapsAsync.isLoading,
                  )),
                ])
              : _NarrowLayout(
                  csvController: _csvController,
                  obsDate: _obsDate,
                  onPickDate: _pickDate,
                  statusMsg: _statusMsg,
                  isError: _isError,
                  parsing: _parsing,
                  onParse: _parseAndSave,
                  snaps: snaps,
                  activeSnap: _activeSnap,
                  onSelectSnap: (s) => setState(() => _activeSnap = s),
                  onDeleteSnap: (s) async {
                    await ref.read(volSurfaceProvider.notifier).delete(s);
                    if (_activeSnap?.ticker == s.ticker && _activeSnap?.obsDateStr == s.obsDateStr) {
                      setState(() => _activeSnap = null);
                    }
                  },
                  tabs: _tabs,
                  ivMode: _ivMode,
                  onIvModeChanged: (m) => setState(() => _ivMode = m),
                  baseSnap: _baseSnap,
                  onBaseSnapChanged: (s) => setState(() => _baseSnap = s),
                  loading: snapsAsync.isLoading,
                  fmtDate: _fmtDate,
                );
        },
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Sidebar
// ═══════════════════════════════════════════════════════════════════════════════
class _Sidebar extends StatelessWidget {
  final TextEditingController csvController;
  final DateTime obsDate;
  final VoidCallback onPickDate;
  final String statusMsg;
  final bool isError;
  final bool parsing;
  final VoidCallback onParse;
  final List<VolSnapshot> snaps;
  final VolSnapshot? activeSnap;
  final ValueChanged<VolSnapshot> onSelectSnap;
  final ValueChanged<VolSnapshot> onDeleteSnap;
  final String Function(DateTime) fmtDate;

  const _Sidebar({
    required this.csvController,
    required this.obsDate,
    required this.onPickDate,
    required this.statusMsg,
    required this.isError,
    required this.parsing,
    required this.onParse,
    required this.snaps,
    required this.activeSnap,
    required this.onSelectSnap,
    required this.onDeleteSnap,
    required this.fmtDate,
  });

  @override
  Widget build(BuildContext context) {
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
              child: Text('ADD SNAPSHOT',
                  style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.2,
                      color: Color(0xFF6b7280),
                      fontFamily: 'monospace')),
            ),
            // ── Date picker ──
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: GestureDetector(
                onTap: onPickDate,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0d1117),
                    border: Border.all(color: const Color(0xFF374151)),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(children: [
                    const Icon(Icons.calendar_today_rounded,
                        size: 13, color: Color(0xFF9ca3af)),
                    const SizedBox(width: 8),
                    Text(fmtDate(obsDate),
                        style: const TextStyle(
                            color: Color(0xFFd1d5db),
                            fontSize: 12,
                            fontFamily: 'monospace')),
                  ]),
                ),
              ),
            ),
            // ── CSV input ──
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
              child: TextField(
                controller: csvController,
                maxLines: 7,
                style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFFd1d5db),
                    fontFamily: 'monospace'),
                decoration: InputDecoration(
                  hintText: 'Paste ThinkorSwim CSV here…',
                  hintStyle: const TextStyle(
                      color: Color(0xFF4b5563), fontSize: 11),
                  filled: true,
                  fillColor: const Color(0xFF0d1117),
                  contentPadding: const EdgeInsets.all(8),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide:
                        const BorderSide(color: Color(0xFF374151)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide:
                        const BorderSide(color: Color(0xFF374151)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide:
                        const BorderSide(color: Color(0xFF3b82f6)),
                  ),
                ),
              ),
            ),
            // ── Status msg ──
            if (statusMsg.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                  decoration: BoxDecoration(
                    color: isError
                        ? const Color(0x1fef4444)
                        : const Color(0x143b82f6),
                    border: Border.all(
                      color: isError
                          ? const Color(0x4def4444)
                          : const Color(0x403b82f6),
                    ),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(statusMsg,
                      style: TextStyle(
                          fontSize: 11,
                          color: isError
                              ? const Color(0xFFfca5a5)
                              : const Color(0xFF93c5fd),
                          fontFamily: 'monospace')),
                ),
              ),
            // ── Parse button ──
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 14),
              child: ElevatedButton(
                onPressed: parsing ? null : onParse,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF3b82f6),
                  foregroundColor: Colors.white,
                  minimumSize: const Size.fromHeight(36),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(6)),
                  textStyle: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      fontFamily: 'monospace'),
                ),
                child: parsing
                    ? const SizedBox(
                        height: 14,
                        width: 14,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Text('Parse & Save'),
              ),
            ),
            const Divider(color: Color(0xFF1f2937), height: 1),
            // ── Datasets list ──
            const Padding(
              padding: EdgeInsets.fromLTRB(14, 12, 14, 6),
              child: Text('DATASETS',
                  style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.2,
                      color: Color(0xFF6b7280),
                      fontFamily: 'monospace')),
            ),
            Expanded(
              child: snaps.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(14),
                      child: Text('No datasets yet.',
                          style: TextStyle(
                              color: Color(0xFF4b5563),
                              fontSize: 11,
                              fontStyle: FontStyle.italic)))
                  : _GroupedDatasetList(
                      snaps: snaps,
                      activeSnap: activeSnap,
                      onSelectSnap: onSelectSnap,
                      onDeleteSnap: onDeleteSnap,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

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
          color: active
              ? const Color(0x183b82f6)
              : Colors.transparent,
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
                Text(snap.obsDateStr,
                    style: const TextStyle(
                        color: Color(0xFFf9fafb),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        fontFamily: 'monospace')),
                const SizedBox(height: 2),
                Text(
                    '${snap.ticker} · ${snap.points.length} rows'
                    '${snap.spotPrice != null ? ' · \$${snap.spotPrice!.toStringAsFixed(2)}' : ''}',
                    style: const TextStyle(
                        color: Color(0xFF6b7280),
                        fontSize: 10,
                        fontFamily: 'monospace')),
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
  final List<VolSnapshot> snaps;
  final VolSnapshot? activeSnap;
  final ValueChanged<VolSnapshot> onSelectSnap;
  final ValueChanged<VolSnapshot> onDeleteSnap;

  const _GroupedDatasetList({
    required this.snaps,
    required this.activeSnap,
    required this.onSelectSnap,
    required this.onDeleteSnap,
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
    // Sort each ticker's snaps newest-first
    for (final v in grouped.values) {
      v.sort((a, b) => b.obsDate.compareTo(a.obsDate));
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: 8),
      children: [
        for (final ticker in grouped.keys) ...[
          _TickerHeader(
            ticker:     ticker,
            count:      grouped[ticker]!.length,
            collapsed:  _collapsed.contains(ticker),
            isActive:   widget.activeSnap?.ticker == ticker,
            onTap: () {
              // Select most recent snapshot for this ticker
              widget.onSelectSnap(grouped[ticker]!.first);
            },
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

  Future<void> _confirmDeleteTicker(BuildContext context, String ticker) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1a1f2e),
        title: Text(
          'Delete all $ticker snapshots?',
          style: const TextStyle(color: Colors.white, fontSize: 15),
        ),
        content: Text(
          'This will permanently remove all ${widget.snaps.where((s) => s.ticker == ticker).length} '
          'uploaded surfaces for $ticker.',
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
            // Collapse toggle
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
            // Ticker name
            Text(
              ticker,
              style: TextStyle(
                color: isActive
                    ? const Color(0xFF60a5fa)
                    : const Color(0xFF93c5fd),
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
                fontFamily: 'monospace',
              ),
            ),
            const SizedBox(width: 6),
            Text(
              '$count',
              style: const TextStyle(
                color: Color(0xFF4b5563),
                fontSize: 10,
                fontFamily: 'monospace',
              ),
            ),
            const Spacer(),
            // Delete all for this ticker
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
  final TabController tabs;
  final String ivMode;
  final ValueChanged<String> onIvModeChanged;
  final List<VolSnapshot> snaps;
  final VolSnapshot? activeSnap;
  final VolSnapshot? baseSnap;
  final ValueChanged<VolSnapshot> onActiveSnapChanged;
  final ValueChanged<VolSnapshot> onBaseSnapChanged;
  final bool loading;

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
        tabs: tabs,
        ivMode: ivMode,
        onIvModeChanged: onIvModeChanged,
        snaps: snaps,
        activeSnap: activeSnap,
        baseSnap: baseSnap,
        onActiveSnapChanged: onActiveSnapChanged,
        onBaseSnapChanged: onBaseSnapChanged,
      ),
      Expanded(child: _ChartArea(
        tabs: tabs,
        activeSnap: activeSnap,
        baseSnap: baseSnap,
        ivMode: ivMode,
        loading: loading,
      )),
      if (activeSnap != null)
        SizedBox(
          height: 220,
          child: VolSurfaceInterpretation(
            snap: activeSnap!,
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
  final TabController tabs;
  final String ivMode;
  final ValueChanged<String> onIvModeChanged;
  final List<VolSnapshot> snaps;
  final VolSnapshot? activeSnap;
  final VolSnapshot? baseSnap;
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
          border:
              Border(bottom: BorderSide(color: Color(0xFF1f2937))),
        ),
        padding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Wrap(
          spacing: 14,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            // View tabs
            _SegmentedControl(
              options: const [
                ('heatmap', 'Heatmap'),
                ('smile', 'Smile'),
                ('diff', 'Diff'),
              ],
              selected: ['heatmap', 'smile', 'diff'][tabs.index],
              onSelected: (v) => tabs.animateTo(
                  ['heatmap', 'smile', 'diff'].indexOf(v)),
            ),
            // IV mode
            _SegmentedControl(
              options: _ivModes,
              selected: ivMode,
              onSelected: onIvModeChanged,
            ),
            // Snapshot selectors for diff mode
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
                    ? snaps.where((s) => s.ticker == activeSnap!.ticker).toList()
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
  final String selected;
  final ValueChanged<String> onSelected;

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
                    left: i == 0 ? const Radius.circular(5) : Radius.zero,
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
                    fontSize: 11,
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
  final String label;
  final List<VolSnapshot> snaps;
  final VolSnapshot? selected;
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
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
              color: Color(0xFF6b7280),
              fontFamily: 'monospace')),
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
                color: Color(0xFF6b7280),
                fontSize: 11,
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
            color: Color(0xFFd1d5db),
            fontSize: 11,
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
  final VolSnapshot? activeSnap;
  final VolSnapshot? baseSnap;
  final String ivMode;
  final bool loading;

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
        // ── Heatmap ──
        activeSnap != null
            ? VolHeatmap(
                points: activeSnap!.points,
                spotPrice: activeSnap!.spotPrice,
                ivMode: ivMode,
              )
            : _empty('Select or add a dataset'),
        // ── Smile ──
        activeSnap != null
            ? VolSmileChart(
                points: activeSnap!.points,
                spotPrice: activeSnap!.spotPrice,
                ivMode: ivMode,
              )
            : _empty('Select or add a dataset'),
        // ── Diff ──
        (activeSnap != null && baseSnap != null)
            ? _DiffHeatmap(
                base: baseSnap!,
                compare: activeSnap!,
                ivMode: ivMode,
              )
            : _empty('Select Base and Compare datasets'),
      ],
    );
  }

  Widget _empty(String msg) => Center(
        child: Text(msg,
            style: const TextStyle(
                color: Color(0xFF4b5563),
                fontSize: 13,
                fontFamily: 'monospace')),
      );
}

// ── Diff heatmap — computes IV(compare) − IV(base) ────────────────────────────
class _DiffHeatmap extends StatelessWidget {
  final VolSnapshot base;
  final VolSnapshot compare;
  final String ivMode;

  const _DiffHeatmap({
    required this.base,
    required this.compare,
    required this.ivMode,
  });

  @override
  Widget build(BuildContext context) {
    // Build lookup maps
    Map<(int, double), double?> ivMap(VolSnapshot s) {
      final m = <(int, double), double?>{};
      for (final p in s.points) {
        m[(p.dte, p.strike)] = p.iv(ivMode, s.spotPrice);
      }
      return m;
    }

    final baseMap = ivMap(base);
    final cmpMap = ivMap(compare);

    // Diff points: only where both have IV
    final diffPoints = <VolPoint>[];
    for (final entry in cmpMap.entries) {
      final bv = baseMap[entry.key];
      final cv = entry.value;
      if (bv != null && cv != null) {
        final diff = cv - bv;
        diffPoints.add(VolPoint(
          strike: entry.key.$2,
          dte: entry.key.$1,
          callIv: diff, // store diff in callIv, use 'call' mode
        ));
      }
    }

    if (diffPoints.isEmpty) {
      return const Center(
          child: Text('No overlapping data between the two datasets',
              style: TextStyle(
                  color: Color(0xFF4b5563),
                  fontSize: 13,
                  fontFamily: 'monospace')));
    }

    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: Row(children: [
          Text('${compare.obsDateStr} − ${base.obsDateStr}',
              style: const TextStyle(
                  color: Color(0xFF9ca3af),
                  fontSize: 11,
                  fontFamily: 'monospace')),
          const SizedBox(width: 12),
          const Text('Red = IV rose  ·  Blue = IV fell',
              style: TextStyle(
                  color: Color(0xFF6b7280),
                  fontSize: 10,
                  fontStyle: FontStyle.italic,
                  fontFamily: 'monospace')),
        ]),
      ),
      Expanded(
        child: VolHeatmap(
          points: diffPoints,
          spotPrice: compare.spotPrice,
          ivMode: 'call',
        ),
      ),
    ]);
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Narrow layout — chart on top, input in modal bottom sheet via FAB
// ═══════════════════════════════════════════════════════════════════════════════
class _NarrowLayout extends StatelessWidget {
  final TextEditingController csvController;
  final DateTime obsDate;
  final VoidCallback onPickDate;
  final String statusMsg;
  final bool isError;
  final bool parsing;
  final VoidCallback onParse;
  final List<VolSnapshot> snaps;
  final VolSnapshot? activeSnap;
  final ValueChanged<VolSnapshot> onSelectSnap;
  final ValueChanged<VolSnapshot> onDeleteSnap;
  final TabController tabs;
  final String ivMode;
  final ValueChanged<String> onIvModeChanged;
  final VolSnapshot? baseSnap;
  final ValueChanged<VolSnapshot> onBaseSnapChanged;
  final bool loading;
  final String Function(DateTime) fmtDate;

  const _NarrowLayout({
    required this.csvController,
    required this.obsDate,
    required this.onPickDate,
    required this.statusMsg,
    required this.isError,
    required this.parsing,
    required this.onParse,
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
    required this.fmtDate,
  });

  void _showInputSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF111827),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
      builder: (_) => Padding(
        padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
            left: 16,
            right: 16,
            top: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            GestureDetector(
              onTap: onPickDate,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFF0d1117),
                  border: Border.all(color: const Color(0xFF374151)),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(children: [
                  const Icon(Icons.calendar_today_rounded,
                      size: 13, color: Color(0xFF9ca3af)),
                  const SizedBox(width: 8),
                  Text(fmtDate(obsDate),
                      style: const TextStyle(
                          color: Color(0xFFd1d5db),
                          fontSize: 12,
                          fontFamily: 'monospace')),
                ]),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: csvController,
              maxLines: 6,
              style: const TextStyle(
                  fontSize: 11,
                  color: Color(0xFFd1d5db),
                  fontFamily: 'monospace'),
              decoration: InputDecoration(
                hintText: 'Paste ThinkorSwim CSV here…',
                hintStyle:
                    const TextStyle(color: Color(0xFF4b5563), fontSize: 11),
                filled: true,
                fillColor: const Color(0xFF0d1117),
                contentPadding: const EdgeInsets.all(8),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: const BorderSide(color: Color(0xFF374151)),
                ),
              ),
            ),
            if (statusMsg.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(statusMsg,
                    style: TextStyle(
                        fontSize: 11,
                        color: isError
                            ? const Color(0xFFfca5a5)
                            : const Color(0xFF93c5fd),
                        fontFamily: 'monospace')),
              ),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: parsing ? null : onParse,
              style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF3b82f6),
                  foregroundColor: Colors.white),
              child: parsing
                  ? const SizedBox(
                      height: 14,
                      width: 14,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Text('Parse & Save'),
            ),
            const SizedBox(height: 16),
          ],
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
            tabs: tabs,
            ivMode: ivMode,
            onIvModeChanged: onIvModeChanged,
            snaps: snaps,
            activeSnap: activeSnap,
            baseSnap: baseSnap,
            onActiveSnapChanged: onSelectSnap,
            onBaseSnapChanged: onBaseSnapChanged,
          ),
          Expanded(child: _ChartArea(
            tabs: tabs,
            activeSnap: activeSnap,
            baseSnap: baseSnap,
            ivMode: ivMode,
            loading: loading,
          )),
          if (activeSnap != null)
            SizedBox(
              height: 220,
              child: VolSurfaceInterpretation(
                snap: activeSnap!,
                ivMode: ivMode,
              ),
            ),
        ]),
        Positioned(
          bottom: activeSnap != null ? 236 : 16,
          right: 16,
          child: FloatingActionButton.extended(
            onPressed: () => _showInputSheet(context),
            backgroundColor: const Color(0xFF3b82f6),
            label: const Text('Add Data',
                style: TextStyle(fontFamily: 'monospace')),
            icon: const Icon(Icons.add_rounded),
          ),
        ),
      ],
    );
  }
}
