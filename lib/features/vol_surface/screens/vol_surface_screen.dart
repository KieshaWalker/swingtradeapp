// =============================================================================
// vol_surface/screens/vol_surface_screen.dart
// =============================================================================
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme.dart';
import '../../../core/widgets/app_menu_button.dart';
import '../models/vol_surface_models.dart';
import '../providers/vol_surface_provider.dart';
import '../widgets/vol_heatmap.dart';
import '../widgets/vol_smile_chart.dart';
import '../widgets/vol_skew_delta_grid.dart';
import '../widgets/vol_surface_guide.dart';
import '../widgets/vol_surface_interpretation.dart';

/// IV convention passed to every chart on this screen.
const _kIvMode = 'otm';

const _kTabKeys   = ['heatmap', 'smile', 'daily'];
const _kTabLabels = ['Heatmap', 'Smile', 'Daily Δ'];

/// Vol-surface chrome palette. The feature keeps its dark "terminal" look
/// (shared with the sibling vol_surface widgets) rather than AppTheme purple.
abstract final class _C {
  static const surface   = Color(0xFF111827); // bars, dropdown background
  static const border    = Color(0xFF1f2937);
  static const control   = Color(0xFF374151); // control borders, drag pill
  static const accent    = Color(0xFF3b82f6);
  static const text      = Color(0xFFd1d5db);
  static const textDim   = Color(0xFF9ca3af);
  static const textMuted = Color(0xFF6b7280);
  static const textFaint = Color(0xFF4b5563);
}

class VolSurfaceScreen extends ConsumerStatefulWidget {
  /// When non-null the screen is scoped to a single ticker (pushed from
  /// TickerProfileScreen). When null the global view is shown, pinned to the
  /// ticker with the most recent snapshot.
  final String? symbol;

  const VolSurfaceScreen({super.key, this.symbol});

  @override
  ConsumerState<VolSurfaceScreen> createState() => _VolSurfaceScreenState();
}

class _VolSurfaceScreenState extends ConsumerState<VolSurfaceScreen>
    with SingleTickerProviderStateMixin {
  VolSnapshot? _activeSnap;
  VolSnapshot? _prevSnap;
  bool _pointsLoading = false;

  /// Bumped on every selection; in-flight point loads from a superseded
  /// selection compare against it and drop their result instead of
  /// clobbering the newer selection.
  int _loadSeq = 0;

  late final TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: _kTabKeys.length, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  List<VolSnapshot> _filterBySymbol(List<VolSnapshot> all) {
    if (widget.symbol == null) return all;
    final sym = widget.symbol!.toUpperCase();
    return [for (final s in all) if (s.ticker == sym) s];
  }

  /// Snapshot list as of now — for event handlers outside build.
  List<VolSnapshot> _visibleSnaps() =>
      _filterBySymbol(ref.read(volSurfaceProvider).valueOrNull ?? []);

  Future<void> _selectSnap(VolSnapshot s) async {
    final seq = ++_loadSeq;
    setState(() {
      _activeSnap    = s;
      _pointsLoading = s.points.isEmpty && s.id != null;
      _prevSnap      = null;
    });
    if (s.points.isEmpty && s.id != null) {
      try {
        final pts =
            await ref.read(volSurfaceRepositoryProvider).loadPoints(s.id!);
        if (!mounted || seq != _loadSeq) return;
        setState(() {
          _activeSnap    = s.copyWith(points: pts);
          _pointsLoading = false;
        });
      } catch (e) {
        debugPrint('vol_surface: failed to load points for ${s.id}: $e');
        if (!mounted || seq != _loadSeq) return;
        setState(() => _pointsLoading = false);
        _showLoadError(s);
        return;
      }
    }
    _findAndLoadPrevSnap(s, seq);
  }

  void _showLoadError(VolSnapshot s) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Failed to load ${s.ticker} ${s.obsDateStr}'),
      action: SnackBarAction(
        label: 'Retry',
        onPressed: () => _selectSnap(s),
      ),
    ));
  }

  void _findAndLoadPrevSnap(VolSnapshot active, int seq) {
    final prev = _visibleSnaps()
        .where((s) =>
            s.ticker == active.ticker && s.obsDate.isBefore(active.obsDate))
        .fold<VolSnapshot?>(null, (best, s) =>
            best == null || s.obsDate.isAfter(best.obsDate) ? s : best);
    if (prev == null) {
      setState(() => _prevSnap = null);
      return;
    }
    // Empty points make VolSkewDeltaGrid show its spinner while they load.
    setState(() => _prevSnap = prev);
    if (prev.points.isEmpty && prev.id != null) _loadPrevPoints(prev, seq);
  }

  Future<void> _loadPrevPoints(VolSnapshot s, int seq) async {
    try {
      final pts =
          await ref.read(volSurfaceRepositoryProvider).loadPoints(s.id!);
      if (!mounted || seq != _loadSeq) return;
      setState(() => _prevSnap = s.copyWith(points: pts));
    } catch (e) {
      debugPrint('vol_surface: failed to load prev points for ${s.id}: $e');
      if (!mounted || seq != _loadSeq) return;
      setState(() => _prevSnap = null);
    }
  }

  // ── Build ───────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final snapsAsync = ref.watch(volSurfaceProvider);
    final snaps      = _filterBySymbol(snapsAsync.valueOrNull ?? []);

    // Auto-select most recent snapshot on first load.
    if (_activeSnap == null && snaps.isNotEmpty) {
      final latest = snaps.reduce((a, b) => a.obsDate.isAfter(b.obsDate) ? a : b);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _activeSnap == null) _selectSnap(latest);
      });
    }

    final isTicker = widget.symbol != null;
    // `hasValue` keeps existing charts visible during a refresh instead of
    // blanking the whole area with a spinner.
    final loading =
        (snapsAsync.isLoading && !snapsAsync.hasValue) || _pointsLoading;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(isTicker
                ? '${widget.symbol!.toUpperCase()} Vol Surface'
                : 'Vol Surface'),
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
      body: snapsAsync.hasError && !snapsAsync.hasValue
          ? _ErrorState(
              error:   snapsAsync.error!,
              onRetry: () => ref.invalidate(volSurfaceProvider),
            )
          : _MainPanel(
              tabs:                _tabs,
              snaps:               snaps,
              activeSnap:          _activeSnap,
              prevSnap:            _prevSnap,
              onActiveSnapChanged: _selectSnap,
              loading:             loading,
            ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Error state — provider load failed with nothing cached
// ═══════════════════════════════════════════════════════════════════════════════
class _ErrorState extends StatelessWidget {
  final Object error;
  final VoidCallback onRetry;

  const _ErrorState({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off_rounded, size: 28, color: _C.textFaint),
          const SizedBox(height: 10),
          const Text('Failed to load vol surfaces',
              style: TextStyle(
                  color:      _C.textDim,
                  fontSize:   13,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              '$error',
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(color: _C.textFaint, fontSize: 11),
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: onRetry,
            style: OutlinedButton.styleFrom(
              foregroundColor: _C.textDim,
              side: const BorderSide(color: _C.control),
            ),
            child: const Text('Retry', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Main panel — controls bar, chart area, resizable interpretation panel
// ═══════════════════════════════════════════════════════════════════════════════
class _MainPanel extends StatefulWidget {
  final TabController             tabs;
  final List<VolSnapshot>         snaps;
  final VolSnapshot?              activeSnap;
  final VolSnapshot?              prevSnap;
  final ValueChanged<VolSnapshot> onActiveSnapChanged;
  final bool                      loading;

  const _MainPanel({
    required this.tabs,
    required this.snaps,
    required this.activeSnap,
    required this.prevSnap,
    required this.onActiveSnapChanged,
    required this.loading,
  });

  @override
  State<_MainPanel> createState() => _MainPanelState();
}

class _MainPanelState extends State<_MainPanel> {
  double _interpHeight = 220;
  static const double _interpMin = 80;
  static const double _interpMax = 440;

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      _ControlsBar(
        tabs:                widget.tabs,
        snaps:               widget.snaps,
        activeSnap:          widget.activeSnap,
        onActiveSnapChanged: widget.onActiveSnapChanged,
      ),
      Expanded(child: _ChartArea(
        tabs:       widget.tabs,
        activeSnap: widget.activeSnap,
        prevSnap:   widget.prevSnap,
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
            color: _C.surface,
            child: Center(
              child: Container(
                width: 36, height: 4,
                decoration: BoxDecoration(
                  color: _C.control,
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
            ivMode: _kIvMode,
          ),
        ),
      ],
    ]);
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Controls bar
// ═══════════════════════════════════════════════════════════════════════════════
class _ControlsBar extends StatefulWidget {
  final TabController             tabs;
  final List<VolSnapshot>         snaps;
  final VolSnapshot?              activeSnap;
  final ValueChanged<VolSnapshot> onActiveSnapChanged;

  const _ControlsBar({
    required this.tabs,
    required this.snaps,
    required this.activeSnap,
    required this.onActiveSnapChanged,
  });

  @override
  State<_ControlsBar> createState() => _ControlsBarState();
}

class _ControlsBarState extends State<_ControlsBar> {
  late int _tabIndex;

  @override
  void initState() {
    super.initState();
    _tabIndex = widget.tabs.index;
    widget.tabs.addListener(_onTabChanged);
  }

  @override
  void didUpdateWidget(_ControlsBar old) {
    super.didUpdateWidget(old);
    if (old.tabs != widget.tabs) {
      old.tabs.removeListener(_onTabChanged);
      widget.tabs.addListener(_onTabChanged);
      _tabIndex = widget.tabs.index;
    }
  }

  @override
  void dispose() {
    widget.tabs.removeListener(_onTabChanged);
    super.dispose();
  }

  void _onTabChanged() {
    if (widget.tabs.index != _tabIndex) {
      setState(() => _tabIndex = widget.tabs.index);
    }
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.activeSnap;

    return Container(
      decoration: const BoxDecoration(
        color: _C.surface,
        border: Border(bottom: BorderSide(color: _C.border)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
            child: _SegmentedControl(
              options: List.generate(
                  _kTabKeys.length, (i) => (_kTabKeys[i], _kTabLabels[i])),
              selected: _kTabKeys[_tabIndex],
              onSelected: (v) => widget.tabs.animateTo(_kTabKeys.indexOf(v)),
            ),
          ),
          if (widget.snaps.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: _SnapSelect(
                label: 'Date',
                snaps: active != null
                    ? widget.snaps
                        .where((s) => s.ticker == active.ticker)
                        .toList()
                    : widget.snaps,
                selected: active,
                onChanged: widget.onActiveSnapChanged,
              ),
            )
          else
            const SizedBox(height: 8),
        ],
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
        border: Border.all(color: _C.control),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < options.length; i++)
            InkWell(
              onTap: () => onSelected(options[i].$1),
              borderRadius: BorderRadius.horizontal(
                left:  i == 0 ? const Radius.circular(5) : Radius.zero,
                right: i == options.length - 1
                    ? const Radius.circular(5)
                    : Radius.zero,
              ),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: selected == options[i].$1
                      ? _C.accent
                      : Colors.transparent,
                  borderRadius: BorderRadius.horizontal(
                    left:  i == 0 ? const Radius.circular(5) : Radius.zero,
                    right: i == options.length - 1
                        ? const Radius.circular(5)
                        : Radius.zero,
                  ),
                  border: i > 0
                      ? const Border(
                          left: BorderSide(color: _C.control))
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
                        : _C.textDim,
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
  final String                    label;
  final List<VolSnapshot>         snaps;
  final VolSnapshot?              selected;
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
              color:        _C.textMuted,
              fontFamily:   'monospace')),
      DropdownButton<VolSnapshot>(
        value: selected != null && snaps.contains(selected) ? selected : null,
        hint: const Text('—',
            style: TextStyle(
                color:     _C.textMuted,
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
        dropdownColor: _C.surface,
        style: const TextStyle(
            color:     _C.text,
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
  final VolSnapshot?  prevSnap;
  final bool          loading;

  const _ChartArea({
    required this.tabs,
    required this.activeSnap,
    required this.prevSnap,
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
                key:       ValueKey('heatmap_${activeSnap!.id}'),
                points:    activeSnap!.points,
                spotPrice: activeSnap!.spotPrice,
                ivMode:    _kIvMode,
              )
            : _empty('Select a date to view the surface'),
        activeSnap != null
            ? VolSmileChart(
                key:       ValueKey('smile_${activeSnap!.id}'),
                points:    activeSnap!.points,
                spotPrice: activeSnap!.spotPrice,
                ivMode:    _kIvMode,
              )
            : _empty('Select a date to view the smile'),
        activeSnap != null
            ? VolSkewDeltaGrid(
                key:      ValueKey('daily_${activeSnap!.id}'),
                snap:     activeSnap!,
                prevSnap: prevSnap,
              )
            : _empty('Select a date to view session changes'),
      ],
    );
  }

  Widget _empty(String msg) => Center(
        child: Text(msg,
            style: const TextStyle(
                color:     _C.textFaint,
                fontSize:  13,
                fontFamily: 'monospace')));
}
