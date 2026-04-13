import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../theme.dart';

class AppMenuButton extends StatelessWidget {
  const AppMenuButton({super.key});

  @override
  Widget build(BuildContext context) {
    final location = GoRouterState.of(context).matchedLocation;

    return PopupMenuButton<String>(
      icon: const Icon(Icons.menu_rounded, color: Colors.white),
      color: AppTheme.elevatedColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      elevation: 12,
      offset: const Offset(0, 8),
      onSelected: (route) => GoRouter.of(context).go(route),
      itemBuilder: (_) => [
        _navItem('/', Icons.home_rounded, 'Home', location),
        _navItem('/trades', Icons.show_chart_rounded, 'Trades', location),
        _navItem('/calculator', Icons.calculate_rounded, 'Calculator', location),
        _navItem('/journal', Icons.book_rounded, 'Journal', location),
        _navItem('/economy', Icons.bar_chart_rounded, 'Economy', location),
        _navItem('/ticker', Icons.candlestick_chart_rounded, 'Tickers', location),
        _navItem('/blotter', Icons.receipt_long_rounded, 'Blotter', location),
        _navItem('/blotter/evaluate', Icons.fact_check_rounded, 'Trade Eval', location),
        _navItem('/vol-surface', Icons.stacked_line_chart_rounded, 'Vol Surface', location),
      ],
    );
  }

  PopupMenuItem<String> _navItem(
    String route,
    IconData icon,
    String label,
    String location,
  ) {
    final isActive = route == '/'
        ? location == '/'
        : location.startsWith(route);

    return PopupMenuItem<String>(
      value: route,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          Icon(
            icon,
            size: 18,
            color: isActive ? AppTheme.profitColor : Colors.white70,
          ),
          const SizedBox(width: 12),
          Text(
            label,
            style: TextStyle(
              color: isActive ? AppTheme.profitColor : Colors.white,
              fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
              fontSize: 14,
            ),
          ),
          if (isActive) ...[
            const Spacer(),
            Container(
              width: 6,
              height: 6,
              decoration: const BoxDecoration(
                color: AppTheme.profitColor,
                shape: BoxShape.circle,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
