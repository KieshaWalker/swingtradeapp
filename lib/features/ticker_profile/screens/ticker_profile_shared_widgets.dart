// =============================================================================
// features/ticker_profile/screens/ticker_profile_shared_widgets.dart
// =============================================================================
// Shared small utility widgets used across ticker profile tabs:
//   SectionHeader, LoadingCard, ErrorCard, EmptyCard
// =============================================================================

import 'package:flutter/material.dart';
import '../../../core/theme.dart';

class SectionHeader extends StatelessWidget {
  final String text;
  const SectionHeader(this.text, {super.key});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          text,
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            color: AppTheme.neutralColor,
            fontSize: 12,
            letterSpacing: 1,
          ),
        ),
      );
}

class LoadingCard extends StatelessWidget {
  const LoadingCard({super.key});
  @override
  Widget build(BuildContext context) => const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Center(child: CircularProgressIndicator()),
        ),
      );
}

class ErrorCard extends StatelessWidget {
  final String message;
  const ErrorCard(this.message, {super.key});
  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(message,
              style: const TextStyle(color: AppTheme.lossColor)),
        ),
      );
}

class EmptyCard extends StatelessWidget {
  final String message;
  const EmptyCard(this.message, {super.key});
  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(message,
              style: const TextStyle(color: AppTheme.neutralColor)),
        ),
      );
}
