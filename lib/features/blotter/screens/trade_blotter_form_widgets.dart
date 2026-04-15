// =============================================================================
// features/blotter/screens/trade_blotter_form_widgets.dart
// =============================================================================
// Form input widgets used by TradeBlotterScreen's builder tab:
//   _LifecycleStepper, _SectionCard, _TerminalField, _UpperCaseFormatter,
//   _TypeToggle, _DatePickerField, _StrategyDropdown
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../core/theme.dart';
import '../models/blotter_models.dart';

// ── Lifecycle stepper ─────────────────────────────────────────────────────────

class LifecycleStepper extends StatelessWidget {
  final TradeStatus status;
  const LifecycleStepper({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    final stages = TradeStatus.values;
    return Container(
      color: const Color(0xFF0F0F14),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: List.generate(stages.length * 2 - 1, (i) {
          if (i.isOdd) {
            // Connector line
            final reached = status.index > i ~/ 2;
            return Expanded(
              child: Container(
                height: 2,
                color: reached
                    ? stages[i ~/ 2].color.withValues(alpha: 0.6)
                    : const Color(0xFF2A2A38),
              ),
            );
          }
          final stage = stages[i ~/ 2];
          final active = status == stage;
          final done = status.index > stage.index;
          final color = done || active ? stage.color : const Color(0xFF3A3A4A);
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color.withValues(alpha: active ? 0.2 : 0.1),
                  border: Border.all(color: color, width: active ? 2 : 1),
                ),
                child: Center(
                  child: done
                      ? Icon(Icons.check, size: 12, color: color)
                      : Text(
                          '${stage.index + 1}',
                          style: TextStyle(
                            color: color,
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 3),
              Text(
                stage.label,
                style: TextStyle(
                  color: color,
                  fontSize: 8,
                  fontWeight: active ? FontWeight.w800 : FontWeight.w500,
                  letterSpacing: 0.4,
                ),
              ),
            ],
          );
        }),
      ),
    );
  }
}

// ── Section card shell ────────────────────────────────────────────────────────

class SectionCard extends StatelessWidget {
  final String label;
  final Color accent;
  final Widget child;
  const SectionCard({
    super.key,
    required this.label,
    required this.accent,
    required this.child,
  });

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: const Color(0xFF16161F),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: const Color(0xFF2A2A38)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.07),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(10)),
            border: Border(
              bottom: BorderSide(color: accent.withValues(alpha: 0.2)),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 3,
                height: 12,
                decoration: BoxDecoration(
                  color: accent,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  color: accent,
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.2,
                ),
              ),
            ],
          ),
        ),
        Padding(padding: const EdgeInsets.all(14), child: child),
      ],
    ),
  );
}

// ── Terminal-style text field ─────────────────────────────────────────────────

class TerminalField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final String hint;
  final bool numeric;
  final bool caps;
  final int maxLines;
  final String? Function(String?)? validator;
  final void Function(String)? onChanged;

  const TerminalField({
    super.key,
    required this.label,
    required this.controller,
    required this.hint,
    this.numeric = false,
    this.caps = false,
    this.maxLines = 1,
    this.validator,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: const TextStyle(
          color: Color(0xFF6B7280),
          fontSize: 9,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.0,
        ),
      ),
      const SizedBox(height: 4),
      TextFormField(
        controller: controller,
        maxLines: maxLines,
        onChanged: onChanged,
        validator: validator,
        keyboardType: numeric
            ? const TextInputType.numberWithOptions(decimal: true)
            : TextInputType.text,
        inputFormatters: [if (caps) UpperCaseFormatter()],
        style: const TextStyle(
          color: Colors.white,
          fontSize: 14,
          fontWeight: FontWeight.w600,
          fontFamily: 'monospace',
        ),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: const TextStyle(color: Color(0xFF3A3A4A), fontSize: 13),
          filled: true,
          fillColor: const Color(0xFF0F0F14),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 10,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: const BorderSide(color: Color(0xFF2A2A38)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: const BorderSide(color: Color(0xFF2A2A38)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: const BorderSide(color: Color(0xFF60A5FA)),
          ),
          errorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: BorderSide(
              color: AppTheme.lossColor.withValues(alpha: 0.6),
            ),
          ),
          errorStyle: const TextStyle(color: AppTheme.lossColor, fontSize: 10),
        ),
      ),
    ],
  );
}

class UpperCaseFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue _,
    TextEditingValue newVal,
  ) => newVal.copyWith(text: newVal.text.toUpperCase());
}

// ── Call / Put toggle ─────────────────────────────────────────────────────────

class TypeToggle extends StatelessWidget {
  final ContractType value;
  final void Function(ContractType) onChanged;
  const TypeToggle({super.key, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'TYPE',
          style: TextStyle(
            color: Color(0xFF6B7280),
            fontSize: 9,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.0,
          ),
        ),
        const SizedBox(height: 4),
        Row(
          children: ContractType.values.map((t) {
            final sel = value == t;
            final color = t == ContractType.call
                ? AppTheme.profitColor
                : AppTheme.lossColor;
            return Expanded(
              child: GestureDetector(
                onTap: () => onChanged(t),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  margin: EdgeInsets.only(
                    right: t == ContractType.call ? 4 : 0,
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    color: sel
                        ? color.withValues(alpha: 0.18)
                        : const Color(0xFF0F0F14),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: sel ? color : const Color(0xFF2A2A38),
                    ),
                  ),
                  child: Text(
                    t.label,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: sel ? color : const Color(0xFF6B7280),
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }
}

// ── Expiration date picker ────────────────────────────────────────────────────

class DatePickerField extends StatelessWidget {
  final DateTime? value;
  final void Function(DateTime) onPicked;
  const DatePickerField({super.key, required this.value, required this.onPicked});

  String get _label => value == null
      ? 'SELECT DATE'
      : '${value!.year}-'
            '${value!.month.toString().padLeft(2, '0')}-'
            '${value!.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(
        'EXPIRATION',
        style: TextStyle(
          color: Color(0xFF6B7280),
          fontSize: 9,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.0,
        ),
      ),
      const SizedBox(height: 4),
      GestureDetector(
        onTap: () async {
          final d = await showDatePicker(
            context: context,
            initialDate: DateTime.now().add(const Duration(days: 30)),
            firstDate: DateTime.now(),
            lastDate: DateTime.now().add(const Duration(days: 730)),
            builder: (ctx, child) => Theme(
              data: ThemeData.dark().copyWith(
                colorScheme: const ColorScheme.dark(
                  primary: Color(0xFF60A5FA),
                  surface: Color(0xFF16161F),
                ),
              ),
              child: child ?? const SizedBox.shrink(),
            ),
          );
          if (d != null) onPicked(d);
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: BoxDecoration(
            color: const Color(0xFF0F0F14),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: value != null
                  ? const Color(0xFF60A5FA).withValues(alpha: 0.5)
                  : const Color(0xFF2A2A38),
            ),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.calendar_today_outlined,
                color: Color(0xFF60A5FA),
                size: 14,
              ),
              const SizedBox(width: 10),
              Text(
                _label,
                style: TextStyle(
                  color: value != null ? Colors.white : const Color(0xFF3A3A4A),
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
        ),
      ),
    ],
  );
}

// ── Strategy dropdown ─────────────────────────────────────────────────────────

class StrategyDropdown extends StatelessWidget {
  final StrategyTag value;
  final void Function(StrategyTag) onChanged;
  const StrategyDropdown({super.key, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(
        'STRATEGY TAG',
        style: TextStyle(
          color: Color(0xFF6B7280),
          fontSize: 9,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.0,
        ),
      ),
      const SizedBox(height: 4),
      DropdownButtonFormField<StrategyTag>(
        initialValue: value,
        dropdownColor: const Color(0xFF16161F),
        style: const TextStyle(
          color: Colors.white,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
        decoration: InputDecoration(
          filled: true,
          fillColor: const Color(0xFF0F0F14),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 10,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: const BorderSide(color: Color(0xFF2A2A38)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: const BorderSide(color: Color(0xFF2A2A38)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: const BorderSide(color: Color(0xFF60A5FA)),
          ),
        ),
        items: StrategyTag.values
            .map((t) => DropdownMenuItem(value: t, child: Text(t.label)))
            .toList(),
        onChanged: (t) {
          if (t != null) onChanged(t);
        },
      ),
    ],
  );
}
