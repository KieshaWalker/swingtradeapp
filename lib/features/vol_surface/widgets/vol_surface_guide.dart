// =============================================================================
// vol_surface/widgets/vol_surface_guide.dart
// Contextual trading guide shown from the ? button in the app bar.
// Content adapts to the active tab (heatmap / smile / diff).
// =============================================================================
import 'package:flutter/material.dart';

// ── Entry point ───────────────────────────────────────────────────────────────
void showVolSurfaceGuide(BuildContext context, int tabIndex) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xFF111827),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
    ),
    builder: (_) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (_, controller) => _GuideSheet(
        scrollController: controller,
        tabIndex: tabIndex,
      ),
    ),
  );
}

// ── Sheet ─────────────────────────────────────────────────────────────────────
class _GuideSheet extends StatelessWidget {
  final ScrollController scrollController;
  final int tabIndex;

  const _GuideSheet({
    required this.scrollController,
    required this.tabIndex,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Handle
        Padding(
          padding: const EdgeInsets.only(top: 10, bottom: 4),
          child: Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: const Color(0xFF374151),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
        // Header
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 6, 18, 8),
          child: Row(children: [
            const Icon(Icons.auto_graph_rounded,
                color: Color(0xFF60a5fa), size: 18),
            const SizedBox(width: 8),
            Text(
              ['Reading the Heatmap',
               'Reading the Smile',
               'Reading the Diff'][tabIndex.clamp(0, 2)],
              style: const TextStyle(
                color: Color(0xFFf9fafb),
                fontSize: 15,
                fontWeight: FontWeight.w700,
                fontFamily: 'monospace',
              ),
            ),
          ]),
        ),
        const Divider(color: Color(0xFF1f2937), height: 1),
        // Scrollable content
        Expanded(
          child: ListView(
            controller: scrollController,
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 32),
            children: [
              _quickChecklist(),
              const SizedBox(height: 20),
              ..._tabContent(tabIndex),
              const SizedBox(height: 20),
              _tradeSignals(),
              const SizedBox(height: 20),
              _warningSigns(),
            ],
          ),
        ),
      ],
    );
  }

  // ── Quick checklist ─────────────────────────────────────────────────────────
  Widget _quickChecklist() => _Section(
    title: 'QUICK CHECKLIST',
    color: const Color(0xFF60a5fa),
    children: const [
      _Check('IV Level — IVR > 70 = sell premium · IVR < 30 = buy premium'),
      _Check('Term structure — brighter right = contango (normal) · brighter left = backwardation (stress)'),
      _Check('Skew — steep left = expensive puts (fear) · steep right = expensive calls (speculation)'),
      _Check('Front-month kink — front row much brighter than rest = earnings crush candidate'),
      _Check('Anomalies — isolated bright cell = mispricing or illiquid strike, verify before trading'),
      _Check('DTE — under 7 days? High gamma, avoid short-dated short premium near spot'),
    ],
  );

  // ── Per-tab content ─────────────────────────────────────────────────────────
  List<Widget> _tabContent(int tab) {
    switch (tab) {
      case 0:
        return _heatmapGuide();
      case 1:
        return _smileGuide();
      case 2:
        return _diffGuide();
      default:
        return _heatmapGuide();
    }
  }

  List<Widget> _heatmapGuide() => [
    _Section(
      title: 'WHAT YOU ARE LOOKING AT',
      color: const Color(0xFF4ade80),
      children: const [
        _Body('Each cell = one option contract at a specific strike × DTE. '
            'Color = implied volatility (IV) — the market\'s priced-in expectation of future move. '
            'Warm (red/orange) = expensive premium. Cool (blue) = cheap premium.'),
        _Body('X axis = strike price. Y axis = days to expiration (DTE). '
            'The yellow vertical line = current stock price (spot).'),
      ],
    ),
    const SizedBox(height: 14),
    _Section(
      title: 'TERM STRUCTURE (ROWS)',
      color: const Color(0xFFfbbf24),
      children: const [
        _KV('Contango (normal)', 'Rows get brighter moving down (longer DTE = higher IV). '
            'Market expects more uncertainty the further out you go. '
            'Occurs ~84% of the time in calm markets.'),
        _KV('Backwardation (stress)', 'Top rows (near expirations) are brightest. '
            'Near-term fear or an upcoming event is inflating front-month IV. '
            'Persisting backwardation = sustained market stress — reduce size.'),
        _KV('Calendar spread signal', 'In contango: sell front-month, buy back-month at same strike. '
            'Front-month decays faster, back-month holds vega. '
            'Exit at 30–40% of max risk as profit target.'),
        _KV('Backwardation trade', 'Reverse calendar before earnings: buy short-dated, sell longer-dated. '
            'After event, front-month IV crushes faster → net profit.'),
      ],
    ),
    const SizedBox(height: 14),
    _Section(
      title: 'SKEW (COLUMNS)',
      color: const Color(0xFFf472b6),
      children: const [
        _KV('Left side brighter (put skew)', 'OTM puts are expensive — institutional hedging demand. '
            'Normal for equities. The 25-delta risk reversal measures this: '
            'RR < −5 vol pts = steep skew (rich puts).'),
        _KV('Right side brighter (call skew)', 'OTM calls are expensive — speculative buying or short squeeze. '
            'Rare in equities. Common in meme stocks and pre-catalyst biotech.'),
        _KV('Risk reversal trade', 'Steep put skew (RR < −5): sell 25-delta put, buy 25-delta call. '
            'You collect the put premium excess and hedge with cheap calls. '
            'Profit when skew normalizes toward −2 to −3.'),
        _KV('Flat skew', 'Near-zero RR. Calendar spreads and ratio spreads more attractive. '
            'Risk reversals lose edge.'),
      ],
    ),
    const SizedBox(height: 14),
    _Section(
      title: 'IV LEVEL & PREMIUM RICHNESS',
      color: const Color(0xFF34d399),
      children: const [
        _KV('IV Rank > 70', 'Options historically expensive. Net premium seller. '
            'Sell covered calls, credit spreads, short strangles/straddles.'),
        _KV('IV Rank 30–70', 'Neutral zone. Needs directional conviction or a skew setup to trade.'),
        _KV('IV Rank < 30', 'Options cheap. Net premium buyer. '
            'Long calls/puts, long strangles, debit spreads.'),
        _KV('Vega reminder', 'Back-month options (bottom rows) have 2–3× the vega of front-month. '
            'A 1% IV move = bigger dollar P&L in longer-dated positions.'),
      ],
    ),
  ];

  List<Widget> _smileGuide() => [
    _Section(
      title: 'WHAT YOU ARE LOOKING AT',
      color: const Color(0xFF4ade80),
      children: const [
        _Body('Each line = the vol smile for one expiration (DTE). '
            'X axis = strike. Y axis = IV%. Toggle DTEs with the chips above. '
            'The yellow dashed line = spot price.'),
        _Body('In a Black-Scholes world the smile would be flat. '
            'It never is — the shape tells you what the market fears or expects.'),
      ],
    ),
    const SizedBox(height: 14),
    _Section(
      title: 'SMILE SHAPES',
      color: const Color(0xFFfbbf24),
      children: const [
        _KV('Downward slope (reverse skew)', 'IV rises as strike falls — standard for equities. '
            'Downside puts carry a fear premium. Steeper slope = more crash protection demand.'),
        _KV('Upward slope (forward skew)', 'IV rises as strike rises — call premium is inflated. '
            'Signals speculative buying. Rare; watch for reversal.'),
        _KV('U-shaped (symmetric smile)', 'Both sides elevated, ATM is cheapest. '
            'Extreme uncertainty. Sell the wings — short strangle or short straddle — '
            'expecting IV to normalize after the event.'),
        _KV('Flat smile', 'No skew premium. Balanced market. '
            'Calendar spreads and verticals work best.'),
      ],
    ),
    const SizedBox(height: 14),
    _Section(
      title: 'READING SKEW NUMBERS',
      color: const Color(0xFFf472b6),
      children: const [
        _KV('25-delta risk reversal', 'IV(25Δ call) − IV(25Δ put). '
            'Negative = puts more expensive (normal for stocks). '
            'Below −5 vol pts = steep. Near 0 = flat.'),
        _KV('Steep skew trade', 'Sell 25Δ put (rich), buy 25Δ call (cheap). '
            'Profit when skew flattens back toward −2 to −3. '
            'Works best when IV rank is moderate (30–60).'),
        _KV('Term structure in the smile', 'Compare lines across DTEs at the same strike. '
            'Front-month line significantly higher than back-month at ATM = '
            'backwardation kink. Earnings/event crush is likely imminent.'),
        _KV('Curvature (convexity)', 'A sharply curved smile = the market is pricing '
            'large move potential. Flat smile = quiet market expectation.'),
      ],
    ),
    const SizedBox(height: 14),
    _Section(
      title: 'PRACTICAL READS',
      color: const Color(0xFF818cf8),
      children: const [
        _KV('ATM IV level', 'The center of the smile at spot = cost of a straddle. '
            'ATM IV × 0.8 × √(DTE/365) ≈ expected ±1σ move in dollars.'),
        _KV('Wing spread', 'How far the smile rises from ATM to 10Δ. '
            'Wide wing spread = market pricing fat-tail risk (crash or squeeze).'),
        _KV('Smile flattening', 'If the smile is flattening day over day (lines converging), '
            'the market is becoming more neutral. Reduce directional premium plays.'),
      ],
    ),
  ];

  List<Widget> _diffGuide() => [
    _Section(
      title: 'WHAT YOU ARE LOOKING AT',
      color: const Color(0xFF4ade80),
      children: const [
        _Body('Each cell = IV(Compare date) − IV(Base date) at that strike × DTE. '
            'Red/warm = IV rose (options got more expensive). '
            'Blue/cool = IV fell (options got cheaper, i.e. vol crush).'),
        _Body('Use this to see exactly where the market re-priced after an event — '
            'earnings, FOMC, macro shock — and where residual premium remains.'),
      ],
    ),
    const SizedBox(height: 14),
    _Section(
      title: 'POST-EVENT VOL CRUSH',
      color: const Color(0xFFfbbf24),
      children: const [
        _KV('What crush looks like', 'Entire front-month row turns deep blue after earnings. '
            'Average crush: 38% across large-cap stocks. '
            'Large-cap stable names (JNJ, KO): 25–35%. '
            'High-vol names (NVDA, META): 35–50%. '
            'Speculative (GME, AMC): 50–70%.'),
        _KV('Timing', '~72% of crush occurs at the open after earnings. '
            'Remaining 28% unrolls over 3–5 days. '
            'Trade: exit short premium at open, not the close.'),
        _KV('Residual premium', 'If the diff shows back months barely moved (light color), '
            'the crush was front-month only. Residual IV in back months = '
            'potential to sell or calendar into them.'),
        _KV('Pre-event signal', 'Run diff vs 1 week ago before earnings. '
            'If front-month is warming (red), kink is building — crush is coming. '
            'Short straddle/strangle now, exit at open after earnings.'),
      ],
    ),
    const SizedBox(height: 14),
    _Section(
      title: 'TERM STRUCTURE SHIFT',
      color: const Color(0xFFf472b6),
      children: const [
        _KV('Uniform warm across all rows', 'Whole surface re-priced higher. '
            'Market-wide fear event (macro shock, Fed surprise). '
            'Do not sell premium into this — wait for stabilization.'),
        _KV('Front row warm, back rows neutral', 'Near-term event risk added. '
            'Calendar spread opportunity: sell elevated front, hold back-month.'),
        _KV('Back rows warm, front neutral', 'Long-dated uncertainty rising. '
            'Potential macro regime change. Reduce long-dated short vega exposure.'),
        _KV('Uniform cool across all rows', 'Market-wide vol crush. '
            'Good time to buy premium or enter long calendars.'),
      ],
    ),
    const SizedBox(height: 14),
    _Section(
      title: 'SKEW SHIFT',
      color: const Color(0xFF34d399),
      children: const [
        _KV('Left side cooled, right side warmed', 'Put skew deflated, call skew inflated. '
            'Market shifted from fear to greed. Risk reversal less attractive; watch for reversal.'),
        _KV('Left side warmed, right side neutral', 'Put buyers returned. '
            'Downside hedging demand increased. Consider protective puts or put spreads.'),
        _KV('Both sides warmed (smile widened)', 'Uncertainty increased on all strikes. '
            'Gamma risk elevated. Reduce short-wing exposure.'),
      ],
    ),
  ];

  // ── Shared: trade signals ───────────────────────────────────────────────────
  Widget _tradeSignals() => _Section(
    title: 'TRADE ENTRY SIGNALS',
    color: const Color(0xFF60a5fa),
    children: const [
      _TradeRow(
        signal: 'Steep put skew  (RR < −5)',
        trade: 'Risk Reversal',
        detail: 'Sell 25Δ put · buy 25Δ call · profit when skew normalizes',
      ),
      _TradeRow(
        signal: 'Flat term structure',
        trade: 'Calendar Spread',
        detail: 'Sell front-month ATM · buy back-month ATM · target 30–40% of risk',
      ),
      _TradeRow(
        signal: 'Backwardation kink pre-earnings',
        trade: 'Short Straddle / Strangle',
        detail: 'Sell ATM straddle · exit at open after earnings · collect crush',
      ),
      _TradeRow(
        signal: 'Isolated bright cell (anomaly)',
        trade: 'Ratio Spread',
        detail: 'Buy underpriced neighbor · sell overpriced spike · 2:1 ratio',
      ),
      _TradeRow(
        signal: 'IV Rank > 70, contango intact',
        trade: 'Iron Condor',
        detail: 'Sell 10Δ call + 10Δ put · buy wings · theta decay in your favor',
      ),
      _TradeRow(
        signal: 'IV Rank < 30, flat smile',
        trade: 'Long Strangle',
        detail: 'Buy OTM call + OTM put · profit from any large move or IV expansion',
      ),
    ],
  );

  // ── Shared: warning signs ───────────────────────────────────────────────────
  Widget _warningSigns() => _Section(
    title: 'WARNING SIGNS',
    color: const Color(0xFFf87171),
    children: const [
      _Warning('Backwardation persists or re-inverts over multiple days',
          'Sustained market stress. Reduce size, avoid short premium, buy protection.'),
      _Warning('Front-month IV spikes 5–10% in 1–2 days before earnings',
          'Surface blowout. Options fully priced for event. Don\'t buy calls/puts directionally — IV crush will hurt even if right.'),
      _Warning('ATM front-month < 7 DTE near high-OI strike',
          'Gamma risk + pin risk. MMs rehedge constantly. Short gamma positions can blow up. Roll or close.'),
      _Warning('Isolated bright cell in illiquid strike',
          'Likely stale/wide bid-ask. Don\'t assume arbitrage. Verify with live quote before trading.'),
      _Warning('Skew flips from steep negative to near-zero or positive',
          'Sentiment shift. Risk reversals lose edge. Investigate before acting.'),
      _Warning('Whole surface warming uniformly',
          'Market-wide fear. Do not sell premium. Wait for stabilization before any short-vol trades.'),
    ],
  );
}

// ═══════════════════════════════════════════════════════════════════════════════
// Re-usable building blocks
// ═══════════════════════════════════════════════════════════════════════════════

class _Section extends StatelessWidget {
  final String title;
  final Color color;
  final List<Widget> children;

  const _Section({
    required this.title,
    required this.color,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Container(width: 3, height: 14,
              decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
          const SizedBox(width: 7),
          Text(title,
              style: TextStyle(
                  color: color,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.1,
                  fontFamily: 'monospace')),
        ]),
        const SizedBox(height: 8),
        ...children,
      ],
    );
  }
}

class _Body extends StatelessWidget {
  final String text;
  const _Body(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(text,
          style: const TextStyle(
              color: Color(0xFFd1d5db),
              fontSize: 12,
              height: 1.55,
              fontFamily: 'monospace')),
    );
  }
}

class _KV extends StatelessWidget {
  final String key2;
  final String value;
  const _KV(this.key2, this.value);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 148,
            child: Text(key2,
                style: const TextStyle(
                    color: Color(0xFFf9fafb),
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    height: 1.4,
                    fontFamily: 'monospace')),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(value,
                style: const TextStyle(
                    color: Color(0xFF9ca3af),
                    fontSize: 11,
                    height: 1.5,
                    fontFamily: 'monospace')),
          ),
        ],
      ),
    );
  }
}

class _Check extends StatelessWidget {
  final String text;
  const _Check(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 1),
            child: Icon(Icons.check_box_outline_blank_rounded,
                size: 13, color: Color(0xFF60a5fa)),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Text(text,
                style: const TextStyle(
                    color: Color(0xFFd1d5db),
                    fontSize: 11,
                    height: 1.5,
                    fontFamily: 'monospace')),
          ),
        ],
      ),
    );
  }
}

class _TradeRow extends StatelessWidget {
  final String signal;
  final String trade;
  final String detail;
  const _TradeRow(
      {required this.signal, required this.trade, required this.detail});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 7),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF0d1117),
        border: Border.all(color: const Color(0xFF1f2937)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
              child: Text(signal,
                  style: const TextStyle(
                      color: Color(0xFF9ca3af),
                      fontSize: 10,
                      fontFamily: 'monospace')),
            ),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0x253b82f6),
                border: Border.all(color: const Color(0x403b82f6)),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(trade,
                  style: const TextStyle(
                      color: Color(0xFF60a5fa),
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      fontFamily: 'monospace')),
            ),
          ]),
          const SizedBox(height: 4),
          Text(detail,
              style: const TextStyle(
                  color: Color(0xFFd1d5db),
                  fontSize: 11,
                  height: 1.45,
                  fontFamily: 'monospace')),
        ],
      ),
    );
  }
}

class _Warning extends StatelessWidget {
  final String condition;
  final String action;
  const _Warning(this.condition, this.action);

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 7),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0x0fef4444),
        border: Border.all(color: const Color(0x30ef4444)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 1),
                child: Icon(Icons.warning_amber_rounded,
                    size: 12, color: Color(0xFFf87171)),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(condition,
                    style: const TextStyle(
                        color: Color(0xFFfca5a5),
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        height: 1.4,
                        fontFamily: 'monospace')),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(left: 18),
            child: Text(action,
                style: const TextStyle(
                    color: Color(0xFF9ca3af),
                    fontSize: 11,
                    height: 1.45,
                    fontFamily: 'monospace')),
          ),
        ],
      ),
    );
  }
}
