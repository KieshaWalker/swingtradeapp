// =============================================================================
// features/strategy_tracker/widgets/add_strategy_sheet.dart
// =============================================================================
// Full-featured strategy creation form presented as a scrollable modal sheet.
//
// Sections:
//   1. Name (required, unique per user) + Description
//   2. SMA Conditions  — dynamic list; each row: Above/Below + period picker
//   3. S/R Level       — toggle + optional proximity % field
//   4. Volume          — Above Avg / Any / Below Avg segmented + two toggles
//   5. VIX             — optional condition: < / > / between + value(s)
//   6. SPY             — optional: SMA position or qualitative area
//   7. Custom Criteria — free-form user-defined rules (add / remove)
//   8. Tags            — chip-style tag input
// =============================================================================
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme.dart';
import '../models/strategy_models.dart';
import '../providers/strategy_tracker_provider.dart';

class AddStrategySheet extends ConsumerStatefulWidget {
  const AddStrategySheet({super.key});

  @override
  ConsumerState<AddStrategySheet> createState() => _AddStrategySheetState();
}

class _AddStrategySheetState extends ConsumerState<AddStrategySheet> {
  final _nameCtrl        = TextEditingController();
  final _descCtrl        = TextEditingController();
  final _srProxCtrl      = TextEditingController();
  final _vixValCtrl      = TextEditingController();
  final _vixLowCtrl      = TextEditingController();
  final _vixHighCtrl     = TextEditingController();
  final _customCtrl      = TextEditingController();
  final _tagCtrl         = TextEditingController();

  // SMA conditions: each entry is {sma: 20, position: 'above'|'below'}
  final List<SmaCondition> _smaConditions = [];

  // S/R
  bool   _srRequired = false;

  // Volume
  VolumeCondition _volumeCondition  = VolumeCondition.any;
  bool            _volumeCross      = false;
  bool            _lowerVolume      = false;

  // VIX
  bool   _vixEnabled  = false;
  String _vixOperator = 'lt';  // 'lt' | 'gt' | 'between'

  // SPY
  bool   _spyEnabled  = false;
  String _spyType     = 'sma'; // 'sma' | 'area'
  int    _spySma      = 200;
  String _spyPosition = 'above';
  String _spyArea     = 'at_highs';

  // Custom criteria & tags
  final List<String> _customCriteria = [];
  final List<String> _tags           = [];

  bool _saving = false;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    _srProxCtrl.dispose();
    _vixValCtrl.dispose();
    _vixLowCtrl.dispose();
    _vixHighCtrl.dispose();
    _customCtrl.dispose();
    _tagCtrl.dispose();
    super.dispose();
  }

  VixCondition? get _vixCondition {
    if (!_vixEnabled) return null;
    if (_vixOperator == 'between') {
      final lo = double.tryParse(_vixLowCtrl.text);
      final hi = double.tryParse(_vixHighCtrl.text);
      if (lo == null || hi == null) return null;
      return VixCondition(operator: 'between', low: lo, high: hi);
    }
    final v = double.tryParse(_vixValCtrl.text);
    if (v == null) return null;
    return VixCondition(operator: _vixOperator, value: v);
  }

  SpyCondition? get _spyCondition {
    if (!_spyEnabled) return null;
    if (_spyType == 'sma') {
      return SpyCondition(
          type: 'sma', sma: _spySma, position: _spyPosition);
    }
    return SpyCondition(type: 'area', area: _spyArea);
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      _snack('Strategy name is required');
      return;
    }
    setState(() => _saving = true);
    try {
      final setup = StrategySetup(
        id:               '',
        name:             name,
        description:      _descCtrl.text.trim().isNotEmpty
            ? _descCtrl.text.trim()
            : null,
        tags:             List<String>.from(_tags),
        smaConditions:    List<SmaCondition>.from(_smaConditions),
        srLevelRequired:  _srRequired,
        srProximityPct:   _srRequired
            ? double.tryParse(_srProxCtrl.text)
            : null,
        volumeCondition:  _volumeCondition,
        volumeCrossNeeded: _volumeCross,
        lowerVolumeNeeded: _lowerVolume,
        vixCondition:     _vixCondition,
        spyCondition:     _spyCondition,
        customCriteria:   List<String>.from(_customCriteria),
        createdAt:        DateTime.now(),
      );
      await ref.read(strategyTrackerProvider.notifier).addSetup(setup);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        _snack(e.toString().contains('unique')
            ? 'A strategy with that name already exists'
            : 'Error saving strategy: $e');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _snack(String msg) => ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(msg),
          backgroundColor: AppTheme.lossColor,
        ),
      );

  // ── Build ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      decoration: const BoxDecoration(
        color: AppTheme.cardColor,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: EdgeInsets.only(bottom: bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Drag handle
          Container(
            margin: const EdgeInsets.only(top: 10, bottom: 4),
            width: 36, height: 4,
            decoration: BoxDecoration(
              color: AppTheme.borderColor,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Row(
              children: [
                const Text(
                  'New Strategy',
                  style: TextStyle(
                    fontSize:   18,
                    fontWeight: FontWeight.w800,
                    color:      Colors.white,
                  ),
                ),
                const Spacer(),
                _saving
                    ? const SizedBox(
                        width: 20, height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : TextButton(
                        onPressed: _save,
                        child: const Text(
                          'Save',
                          style: TextStyle(
                            color:      AppTheme.profitColor,
                            fontWeight: FontWeight.w700,
                            fontSize:   15,
                          ),
                        ),
                      ),
              ],
            ),
          ),
          const Divider(height: 1, color: AppTheme.borderColor),
          Flexible(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
              shrinkWrap: true,
              children: [
                // ── 1. Name & description ─────────────────────────────────────
                _SheetSection('Strategy Name'),
                TextField(
                  controller: _nameCtrl,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    hintText:  'e.g. SPY Morning Breakout',
                    hintStyle: TextStyle(color: AppTheme.neutralColor),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _descCtrl,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: 'Description (optional)',
                  ),
                ),

                const SizedBox(height: 20),

                // ── 2. SMA Conditions ─────────────────────────────────────────
                _SheetSection('SMA Conditions'),
                for (int i = 0; i < _smaConditions.length; i++)
                  _SmaRow(
                    condition: _smaConditions[i],
                    onChanged: (c) => setState(() => _smaConditions[i] = c),
                    onRemove:  () => setState(() => _smaConditions.removeAt(i)),
                  ),
                TextButton.icon(
                  onPressed: () => setState(() => _smaConditions.add(
                        const SmaCondition(sma: 20, position: 'above'),
                      )),
                  icon:  const Icon(Icons.add, size: 16),
                  label: const Text('Add SMA Condition'),
                  style: TextButton.styleFrom(
                    foregroundColor: AppTheme.profitColor,
                    padding: EdgeInsets.zero,
                  ),
                ),

                const SizedBox(height: 16),

                // ── 3. Support & Resistance ───────────────────────────────────
                _SheetSection('Support & Resistance'),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Daily S/R level required'),
                  subtitle: const Text(
                    'Price must be near a key daily level',
                    style: TextStyle(color: AppTheme.neutralColor, fontSize: 12),
                  ),
                  value:    _srRequired,
                  onChanged: (v) => setState(() => _srRequired = v),
                  activeThumbColor: AppTheme.profitColor,
                ),
                if (_srRequired) ...[
                  const SizedBox(height: 8),
                  TextField(
                    controller: _srProxCtrl,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(
                          RegExp(r'[0-9.]')),
                    ],
                    decoration: const InputDecoration(
                      labelText: 'Proximity to S/R (optional)',
                      suffixText: '%',
                      hintText:   'e.g. 1.0',
                    ),
                  ),
                ],

                const SizedBox(height: 16),

                // ── 4. Volume ─────────────────────────────────────────────────
                _SheetSection('Volume'),
                _SegmentedRow<VolumeCondition>(
                  options:  VolumeCondition.values,
                  selected: _volumeCondition,
                  label:    (v) => v.label,
                  onSelect: (v) => setState(() => _volumeCondition = v),
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Volume cross trigger needed'),
                  subtitle: const Text(
                    'Requires a volume crossover as entry signal',
                    style: TextStyle(color: AppTheme.neutralColor, fontSize: 12),
                  ),
                  value:    _volumeCross,
                  onChanged: (v) => setState(() => _volumeCross = v),
                  activeThumbColor: AppTheme.profitColor,
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Lower / declining volume needed'),
                  subtitle: const Text(
                    'Consolidation or pullback on decreasing volume',
                    style: TextStyle(color: AppTheme.neutralColor, fontSize: 12),
                  ),
                  value:    _lowerVolume,
                  onChanged: (v) => setState(() => _lowerVolume = v),
                  activeThumbColor: AppTheme.profitColor,
                ),

                const SizedBox(height: 16),

                // ── 5. VIX Condition ──────────────────────────────────────────
                _SheetSection('VIX Condition'),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('VIX must be in a specific area'),
                  value:    _vixEnabled,
                  onChanged: (v) => setState(() => _vixEnabled = v),
                  activeThumbColor: AppTheme.profitColor,
                ),
                if (_vixEnabled) ...[
                  const SizedBox(height: 8),
                  _SegmentedRow<String>(
                    options:  const ['lt', 'gt', 'between'],
                    selected: _vixOperator,
                    label:    (v) => switch (v) {
                          'lt'      => 'VIX <',
                          'gt'      => 'VIX >',
                          'between' => 'Between',
                          _         => v,
                        },
                    onSelect: (v) => setState(() => _vixOperator = v),
                  ),
                  const SizedBox(height: 8),
                  if (_vixOperator == 'between')
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _vixLowCtrl,
                            keyboardType:
                                const TextInputType.numberWithOptions(decimal: true),
                            decoration: const InputDecoration(
                                labelText: 'Low', hintText: '15'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextField(
                            controller: _vixHighCtrl,
                            keyboardType:
                                const TextInputType.numberWithOptions(decimal: true),
                            decoration: const InputDecoration(
                                labelText: 'High', hintText: '25'),
                          ),
                        ),
                      ],
                    )
                  else
                    TextField(
                      controller: _vixValCtrl,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration: InputDecoration(
                        labelText: _vixOperator == 'lt'
                            ? 'VIX below'
                            : 'VIX above',
                        hintText: '20',
                      ),
                    ),
                ],

                const SizedBox(height: 16),

                // ── 6. SPY Condition ──────────────────────────────────────────
                _SheetSection('SPY Condition'),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('SPY must be in a specific area'),
                  value:    _spyEnabled,
                  onChanged: (v) => setState(() => _spyEnabled = v),
                  activeThumbColor: AppTheme.profitColor,
                ),
                if (_spyEnabled) ...[
                  const SizedBox(height: 8),
                  _SegmentedRow<String>(
                    options:  const ['sma', 'area'],
                    selected: _spyType,
                    label:    (v) =>
                        v == 'sma' ? 'vs SMA' : 'Qualitative',
                    onSelect: (v) => setState(() => _spyType = v),
                  ),
                  const SizedBox(height: 8),
                  if (_spyType == 'sma') ...[
                    Row(
                      children: [
                        Expanded(
                          child: _SegmentedRow<String>(
                            options:  const ['above', 'below'],
                            selected: _spyPosition,
                            label:    (v) =>
                                v == 'above' ? 'Above' : 'Below',
                            onSelect: (v) =>
                                setState(() => _spyPosition = v),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _SegmentedRow<int>(
                            options:  const [20, 50, 100, 200],
                            selected: _spySma,
                            label:    (v) => '$v SMA',
                            onSelect: (v) =>
                                setState(() => _spySma = v),
                          ),
                        ),
                      ],
                    ),
                  ] else
                    _SegmentedRow<String>(
                      options: const [
                        'at_highs', 'pulling_back', 'downtrend', 'range'
                      ],
                      selected: _spyArea,
                      label:    SpyCondition.areaLabel,
                      onSelect: (v) => setState(() => _spyArea = v),
                    ),
                ],

                const SizedBox(height: 16),

                // ── 7. Custom Criteria ────────────────────────────────────────
                _SheetSection('Custom Criteria'),
                const Text(
                  'Add any rule not covered above. Each entry becomes a '
                  'checklist item on the strategy detail screen.',
                  style: TextStyle(
                    color:    AppTheme.neutralColor,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 8),
                for (int i = 0; i < _customCriteria.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      children: [
                        const Icon(Icons.check_circle_outline,
                            size: 16, color: AppTheme.profitColor),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _customCriteria[i],
                            style: const TextStyle(
                                color: Colors.white, fontSize: 13),
                          ),
                        ),
                        GestureDetector(
                          onTap: () =>
                              setState(() => _customCriteria.removeAt(i)),
                          child: const Icon(Icons.close,
                              size: 16, color: AppTheme.neutralColor),
                        ),
                      ],
                    ),
                  ),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _customCtrl,
                        decoration: const InputDecoration(
                          hintText: 'e.g. Must see hammer candle on daily',
                          hintStyle:
                              TextStyle(color: AppTheme.neutralColor),
                        ),
                        onSubmitted: (_) => _addCustom(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      onPressed: _addCustom,
                      icon: const Icon(
                        Icons.add_circle_outline,
                        color: AppTheme.profitColor,
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 16),

                // ── 8. Tags ───────────────────────────────────────────────────
                _SheetSection('Tags'),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final tag in _tags)
                      Chip(
                        label:         Text(tag),
                        onDeleted:     () =>
                            setState(() => _tags.remove(tag)),
                        backgroundColor:
                            AppTheme.profitColor.withValues(alpha: 0.12),
                        side: BorderSide(
                          color:
                              AppTheme.profitColor.withValues(alpha: 0.3),
                        ),
                        labelStyle: const TextStyle(
                          color:    AppTheme.profitColor,
                          fontSize: 12,
                        ),
                        deleteIconColor: AppTheme.neutralColor,
                      ),
                    SizedBox(
                      width: 140,
                      child: TextField(
                        controller: _tagCtrl,
                        decoration: const InputDecoration(
                          hintText:      'Add tag…',
                          hintStyle:
                              TextStyle(color: AppTheme.neutralColor),
                          isDense: true,
                          contentPadding:
                              EdgeInsets.symmetric(vertical: 8, horizontal: 10),
                        ),
                        onSubmitted: (_) => _addTag(),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 24),

                ElevatedButton(
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? const SizedBox(
                          width: 18, height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.black,
                          ),
                        )
                      : const Text('Save Strategy'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _addCustom() {
    final text = _customCtrl.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _customCriteria.add(text);
      _customCtrl.clear();
    });
  }

  void _addTag() {
    final tag = _tagCtrl.text.trim();
    if (tag.isEmpty || _tags.contains(tag)) return;
    setState(() {
      _tags.add(tag);
      _tagCtrl.clear();
    });
  }
}

// ── SMA condition row ─────────────────────────────────────────────────────────

class _SmaRow extends StatelessWidget {
  final SmaCondition condition;
  final ValueChanged<SmaCondition> onChanged;
  final VoidCallback               onRemove;
  const _SmaRow({
    required this.condition,
    required this.onChanged,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          children: [
            // Position toggle
            Expanded(
              child: _SegmentedRow<String>(
                options:  const ['above', 'below'],
                selected: condition.position,
                label:    (v) => v == 'above' ? 'Above' : 'Below',
                onSelect: (v) => onChanged(
                    SmaCondition(sma: condition.sma, position: v)),
              ),
            ),
            const SizedBox(width: 8),
            // SMA period picker
            Expanded(
              child: _SegmentedRow<int>(
                options:  const [20, 50, 100, 200],
                selected: condition.sma,
                label:    (v) => '$v',
                onSelect: (v) => onChanged(
                    SmaCondition(sma: v, position: condition.position)),
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              onPressed: onRemove,
              icon: const Icon(Icons.remove_circle_outline,
                  size: 18, color: AppTheme.lossColor),
              padding:     EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
          ],
        ),
      );
}

// ── Segmented control ─────────────────────────────────────────────────────────

class _SegmentedRow<T> extends StatelessWidget {
  final List<T>     options;
  final T           selected;
  final String Function(T) label;
  final ValueChanged<T>    onSelect;

  const _SegmentedRow({
    required this.options,
    required this.selected,
    required this.label,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) => Row(
        children: options.map((opt) {
          final isSelected = opt == selected;
          return Expanded(
            child: GestureDetector(
              onTap: () => onSelect(opt),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                margin: const EdgeInsets.only(right: 3),
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  color: isSelected
                      ? AppTheme.profitColor.withValues(alpha: 0.18)
                      : AppTheme.elevatedColor,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: isSelected
                        ? AppTheme.profitColor.withValues(alpha: 0.6)
                        : AppTheme.borderColor.withValues(alpha: 0.3),
                  ),
                ),
                child: Text(
                  label(opt),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize:   11,
                    fontWeight: FontWeight.w700,
                    color:      isSelected
                        ? AppTheme.profitColor
                        : AppTheme.neutralColor,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          );
        }).toList(),
      );
}

// ── Section header ─────────────────────────────────────────────────────────────

class _SheetSection extends StatelessWidget {
  final String text;
  const _SheetSection(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(
          text.toUpperCase(),
          style: const TextStyle(
            color:         AppTheme.neutralColor,
            fontSize:      11,
            fontWeight:    FontWeight.w700,
            letterSpacing: 1.0,
          ),
        ),
      );
}
