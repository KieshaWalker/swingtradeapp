// features/economy/data/crisis_history.dart — the 13-crisis evidence base
//
// Static historical record backing the Crisis tab: every U.S. market crisis
// 1873-2022 with its lead-up, trigger, causes, visible warnings, macro
// backdrop, and outcome. Sources: NBER, NYSE/S&P records, standard histories;
// derivation in the repo's data/ folder (Crisis Ledger). Facts only — dates
// and figures are the consensus record, approximations marked with ≈.
//
// signalsPresent keys match the live checklist verdict columns so the history
// screen can highlight which of each crisis's warnings are firing today:
//   index_ath, valuation, leverage, spec_tier, fed, curve,
//   public_credit, private_credit, breadth

class CrisisRecord {
  final String name;
  final String years;
  final String index; // which index/measure the numbers refer to
  final String peak; // date · level
  final String trough; // date · level
  final String drawdown; // headline decline
  final String declineLength;
  final String leadUp; // what price/volume did in the months before
  final String trigger;
  final String causes;
  final String warnings; // what was visible before
  final String inflation;
  final String bonds;
  final String recession;
  final String recovery; // time to reclaim the peak
  final String precedingBull;
  final String aftermath;
  final List<String> signalsPresent;

  const CrisisRecord({
    required this.name,
    required this.years,
    required this.index,
    required this.peak,
    required this.trough,
    required this.drawdown,
    required this.declineLength,
    required this.leadUp,
    required this.trigger,
    required this.causes,
    required this.warnings,
    required this.inflation,
    required this.bonds,
    required this.recession,
    required this.recovery,
    required this.precedingBull,
    required this.aftermath,
    required this.signalsPresent,
  });
}

/// Human labels for signal keys (shared with the live checklist).
const crisisSignalLabels = <String, String>{
  'index_ath': 'Index at highs',
  'valuation': 'Valuation extreme',
  'leverage': 'Record leverage',
  'spec_tier': 'Spec tier peaked first',
  'fed': 'Fed tightening',
  'curve': 'Curve inverted',
  'public_credit': 'Public credit stress',
  'private_credit': 'Opaque credit stress',
  'breadth': 'Breadth divergence',
};

const crisisHistory = <CrisisRecord>[
  CrisisRecord(
    name: 'Panic of 1873 — the Long Depression',
    years: '1873–1877',
    index: 'Pre-index era; railroad securities',
    peak: 'Rail securities peak, early 1873',
    trough: 'Depression trough 1877–78',
    drawdown: '≈−60% typical rail equity',
    declineLength: 'Panic in weeks; 65-month depression (longest NBER ever)',
    leadUp:
        '33,000 miles of track laid in five postwar years, financed by bonds '
        'sold to European savers. Vienna crashed in May 1873; the U.S. shrugged '
        'for four months.',
    trigger:
        'Jay Cooke & Co. — financier of the Northern Pacific — failed Sep 18, '
        '1873, unable to place any more railroad bonds. NYSE closed ten days.',
    causes:
        'Railroad overbuild on bonded debt; European credit contraction after '
        'the Franco-Prussian indemnity; silver demonetized ("Crime of \'73").',
    warnings:
        'Cooke\'s bond placements had been failing for months — visible to the '
        'street. Vienna\'s crash was four months of warning.',
    inflation:
        'Secular deflation: prices fell ~20% across the decade, making fixed '
        'rail debt unpayable.',
    bonds:
        'Rail bonds defaulted en masse; call money spiked; governments held.',
    recession: 'Yes — 65 months, the longest contraction on record.',
    recovery: 'Boom resumed 1879–81 (≈6 years).',
    precedingBull: 'Post-Civil-War railroad boom, 1865–73 (~8 years).',
    aftermath:
        'Receivership wave; clearing-house scrip; no central bank until 1913.',
    signalsPresent: ['private_credit', 'spec_tier'],
  ),
  CrisisRecord(
    name: 'Panic of 1893 — the railroad shakeout',
    years: '1893–1897',
    index: 'Pre-index era; rail-heavy lists',
    peak: 'Rail-heavy lists peak, 1892',
    trough: '1896 (Bryan election scare)',
    drawdown: '≈−50% rail equity; many roads to zero',
    declineLength: '~3 years of failures',
    leadUp:
        'Mileage and debt still growing into 1893 after the biggest '
        'construction decade ever; the Treasury gold reserve slid below \$100M '
        'through 1892 in public monthly statements.',
    trigger:
        'Philadelphia & Reading failed Feb 20, 1893; gold-reserve scare and '
        'the Sherman Silver repeal fight followed.',
    causes:
        'A decade of overbuild; watered capital; fixed charges exceeded '
        'earnings across the industry at any competitive rate.',
    warnings:
        'Receiverships rising through 1892; gold outflows published monthly.',
    inflation: 'Deflation ≈−2 to −4%/yr — falling prices vs fixed coupons.',
    bonds:
        'Rail bonds in default; Treasury rescued by a Morgan syndicate bond '
        'issue in 1895.',
    recession: 'Yes — double-dip 1893–97; unemployment ≈18%.',
    recovery: '≈4 years — 1897 reorganizations plus gold inflows.',
    precedingBull: 'The 1880s buildout: ~70,000 new miles.',
    aftermath:
        '150+ railroads (≈¼ of national mileage) in receivership; '
        '"Morganization"; six-system consolidation; the fortunes were made '
        'buying reorganized assets after the wipeout.',
    signalsPresent: ['private_credit', 'leverage'],
  ),
  CrisisRecord(
    name: 'Panic of 1907 — the Bankers\' Panic',
    years: '1906–1908',
    index: 'Dow Jones Industrial Average',
    peak: 'Jan 1906 · 103.0',
    trough: 'Nov 15, 1907 · 53.0',
    drawdown: '−48.5%',
    declineLength: '22 months, staged (March and October legs)',
    leadUp:
        'Already −25% by September (the March "rich man\'s panic" was the '
        'first leg). Money rates had been stressed for a year; the 1906 San '
        'Francisco earthquake drained gold and insurance capital.',
    trigger:
        'A failed corner on United Copper (Oct 16) triggered a run on the '
        'Knickerbocker Trust (Oct 22). Call money touched 125%. J.P. Morgan\'s '
        'library meetings substituted for a central bank.',
    causes:
        'No lender of last resort; trust companies levered outside '
        'clearing-house rules.',
    warnings:
        'The Bank of England restricted American finance bills in 1906; rate '
        'stress was visible all year.',
    inflation: '+4% (1907) → −2% (1908).',
    bonds: 'No Fed. Clearing-house scrip substituted for cash.',
    recession: 'Yes — sharp, 13 months.',
    recovery: '≈2 years to near the peak (1909); durably above by 1915–16.',
    precedingBull: '1904–06, ≈+65%.',
    aftermath: 'Aldrich–Vreeland Act (1908) → the Federal Reserve (1913).',
    signalsPresent: ['public_credit'],
  ),
  CrisisRecord(
    name: 'The Great Crash',
    years: '1929–1932',
    index: 'Dow Jones Industrial Average',
    peak: 'Sep 3, 1929 · 381.17',
    trough: 'Jul 8, 1932 · 41.22',
    drawdown: '−89.2%',
    declineLength: '34 months',
    leadUp:
        '+27% Jan–Sep 1929, +90% over two years; the final high came on '
        'narrowing leadership. Broker loans hit a record \$8.5B, up ~50% in '
        'twelve months — published weekly. Black Tuesday traded 16.4M shares, '
        'a record that stood ~39 years.',
    trigger:
        'No single event: the Hatry collapse in London (Sep 20), the Fed at '
        '6%, then a margin-call cascade Oct 24–29.',
    causes:
        'A leverage pyramid (broker loans, investment trusts); Fed tightening '
        '1928–29; industrial production had peaked in June — the recession '
        'began in August, before the crash.',
    warnings:
        'Curve inverted in 1928; broker loans parabolic and public; the rails '
        'never confirmed the final high (the original breadth divergence); '
        'Babson\'s warning Sep 5.',
    inflation:
        '~0% at the peak → deflation −8.9% (1931), −10.3% (1932); ≈−27% '
        'cumulative.',
    bonds:
        'Long Treasuries rallied (flight to quality); Baa corporate yields '
        'rose 5.9% → 11%+ by 1932 — credit was destroyed.',
    recession:
        'The Great Depression: GDP −26%, unemployment 25%, 9,000+ bank '
        'failures.',
    recovery: '25.2 years — Nov 23, 1954 (real terms: ~1958).',
    precedingBull: 'Aug 1921 – Sep 1929: 8.1 years, +497%.',
    aftermath:
        'Glass–Steagall, the Securities Acts, the SEC, FDIC, margin Reg T.',
    signalsPresent: [
      'index_ath', 'valuation', 'leverage', 'spec_tier', 'fed', 'curve',
      'breadth',
    ],
  ),
  CrisisRecord(
    name: 'The 1937 relapse',
    years: '1937–1938',
    index: 'Dow Jones Industrial Average',
    peak: 'Mar 10, 1937 · 194.4',
    trough: 'Mar 31, 1938 · 98.95',
    drawdown: '−49.1%',
    declineLength: '12.7 months',
    leadUp: 'The 1935–36 recovery rally (+80%) peaked on rising commodity prices.',
    trigger:
        'The Fed doubled reserve requirements (1936–37) while the Treasury '
        'sterilized gold and fiscal support was withdrawn.',
    causes:
        'Premature tightening into a fragile recovery — the textbook policy '
        'error, cited by every Fed since.',
    warnings: 'The reserve-requirement doublings were pre-announced.',
    inflation: '+3.6% (1937) → −2.1% (1938).',
    bonds: 'Yields ~2.7%, stable — bonds were fine.',
    recession: 'Yes — industrial production fell 32%.',
    recovery: '8.7 years — 1945, under a wartime economy.',
    precedingBull: '1932–37: +372% off the Depression low.',
    aftermath: 'The "don\'t tighten too early" doctrine.',
    signalsPresent: ['index_ath', 'fed'],
  ),
  CrisisRecord(
    name: 'The Kennedy Slide',
    years: '1961–1962',
    index: 'S&P 500',
    peak: 'Dec 12, 1961 · 72.64',
    trough: 'Jun 26, 1962 · 52.32',
    drawdown: '−28.0%',
    declineLength: '6.5 months',
    leadUp:
        '1961 gained +27% amid the "-tronics" IPO mania; the S&P traded at a '
        'record P/E of 22.',
    trigger:
        'No external event — a valuation break. Kennedy\'s clash with U.S. '
        'Steel (Apr 10) accelerated it; May 28 fell 5.7%, the worst day since '
        '1929.',
    causes: 'Valuation excess alone — the rare "clean" re-rating.',
    warnings: 'Record P/E; IPO froth; margin rules tightened in 1961.',
    inflation: '+1.2% — quiescent.',
    bonds: '10-year ~4%, steady; mild bond rally.',
    recession: 'No.',
    recovery: '1.8 years — September 1963.',
    precedingBull: 'The secular 1949–61 run: +436%.',
    aftermath: 'The SEC Special Study of Markets.',
    signalsPresent: ['index_ath', 'valuation'],
  ),
  CrisisRecord(
    name: 'The Go-Go bust',
    years: '1968–1970',
    index: 'S&P 500',
    peak: 'Nov 29, 1968 · 108.37',
    trough: 'May 26, 1970 · 69.29',
    drawdown: '−36.1%',
    declineLength: '18 months',
    leadUp:
        'Conglomerate merger mania and go-go fund speculation; small caps led '
        'through 1967–68. The 1968 back-office "paper crisis" forced the '
        'exchanges to close on Wednesdays.',
    trigger:
        'The 1969 credit crunch; then Penn Central failed Jun 21, 1970 — the '
        'largest bankruptcy to date — freezing the commercial-paper market '
        'until the Fed backstopped it.',
    causes:
        'Vietnam plus Great Society deficits → inflation → tight money; '
        'conglomerate accounting games.',
    warnings:
        'Curve inverted Dec 1968; the A/D line peaked in early 1968; go-go '
        'funds were closing to new money.',
    inflation: '1.6% (1965) → 5.9% (1970).',
    bonds:
        '10-year 6% → 7.9%; bonds fell WITH stocks until the Penn Central '
        'rescue, then rallied.',
    recession: 'Yes — mild (Dec 1969 – Nov 1970).',
    recovery: '3.3 years — March 1972.',
    precedingBull: '1962–68 (+80%), speculative finish.',
    aftermath: 'SIPC (1970); the Fed\'s commercial-paper backstop precedent.',
    signalsPresent: ['index_ath', 'spec_tier', 'fed', 'curve', 'breadth'],
  ),
  CrisisRecord(
    name: 'The Oil / Nifty Fifty bear',
    years: '1973–1974',
    index: 'S&P 500',
    peak: 'Jan 11, 1973 · 120.24',
    trough: 'Oct 3, 1974 · 62.28',
    drawdown: '−48.2% (Dow −45%)',
    declineLength: '21 months',
    leadUp:
        'The January top came on the narrowest leadership of the era: the '
        'Nifty Fifty at 40–90× earnings while the median stock had already '
        'fallen through all of 1972. Volume shrank through the bear — '
        'attrition, not climax.',
    trigger:
        'The bear began nine months before OPEC: Bretton Woods\' end and two '
        'dollar devaluations came first. The Oct 17, 1973 embargo (oil '
        '\$3→\$12) broke it open. Watergate ran underneath.',
    causes:
        'The monetary anchor failed; CPI accelerated 3.4% → 12.3%; two-tier '
        'market concentration.',
    warnings:
        'Curve inverted Jun 1973; breadth negative through all of 1972; '
        'inflation accelerating for a year.',
    inflation: '3.4% (1972) → 11.0% (1974), peak 12.3%.',
    bonds:
        '10-year 6.4% → 8%+, Fed funds 13% — deeply negative real returns. '
        'NOTHING hedged; the classic inflationary bear.',
    recession: 'Yes — Nov 1973 – Mar 1975, severe.',
    recovery:
        '7.5 years nominal (Jul 1980); real recovery not until the mid-1980s.',
    precedingBull: 'May 1970 – Jan 1973: 2.6 years, +74%.',
    aftermath:
        'ERISA (1974); May Day 1975 commission deregulation; the first index '
        'funds.',
    signalsPresent: ['index_ath', 'spec_tier', 'fed', 'curve', 'breadth'],
  ),
  CrisisRecord(
    name: 'Black Monday',
    years: '1987',
    index: 'S&P 500',
    peak: 'Aug 25, 1987 · 336.77',
    trough: 'Dec 4, 1987 · 223.92',
    drawdown: '−33.5% (−20.5% in ONE day)',
    declineLength: '3.3 months; the core damage in four days',
    leadUp:
        '+39% YTD at the August peak; the 10-year yield rose 7.2% → 10.2% '
        'through the year; −10.4% in the three sessions before Black Monday. '
        'Oct 19 traded 604M shares — double the previous record; the tape ran '
        'hours late.',
    trigger:
        'Portfolio-insurance forced selling (~\$60–90B of mechanical '
        'strategies) plus Treasury Secretary Baker\'s weekend dollar comments. '
        'No fundamental news.',
    causes:
        'Rates up 300bp in nine months; twin deficits; a crowded mechanical '
        'strategy selling into its own delta.',
    warnings:
        'The rate rise was public; the record specialist shorts and the '
        'Oct 14–16 warning leg were visible.',
    inflation: '1.1% (1986) → 4.4% (late 1987) — a reflation scare.',
    bonds:
        'The cause and the cure: yields collapsed on Black Monday — bonds '
        'rallied hard.',
    recession: 'No — crash without recession.',
    recovery: '1.9 years — July 1989.',
    precedingBull: 'Aug 1982 – Aug 1987: 5.0 years, +229%.',
    aftermath:
        'Circuit breakers (1988); the Brady Report; Greenspan\'s liquidity '
        'pledge — the "Fed put" born.',
    signalsPresent: ['index_ath', 'fed'],
  ),
  CrisisRecord(
    name: 'The dot-com bust',
    years: '2000–2002',
    index: 'Nasdaq Composite / S&P 500',
    peak: 'Nasdaq Mar 10, 2000 · 5,048.62 (S&P Mar 24 · 1,527.46)',
    trough: 'Nasdaq Oct 10, 2002 · 1,114.11 (S&P Oct 9 · 776.76)',
    drawdown: 'Nasdaq −77.9% · S&P −49.1%',
    declineLength: '31 months',
    leadUp:
        'Nasdaq +86% in 1999 and +24% more in ten weeks; record IPO volume '
        'with average first-day pops near +90%; CAPE 44.2 — the all-time '
        'record; margin debt peaked in March 2000, the month of the top.',
    trigger:
        'No single event: in March 2000 the Microsoft antitrust ruling, '
        'Barron\'s dot-com cash-burn cover, and a closed IPO window arrived '
        'together. Then 9/11, then Enron and WorldCom.',
    causes:
        'A capex bubble — telecom lost ≈\$2T and lit under 5% of its fiber; '
        'profitless-growth valuations; the Fed at 6.5%.',
    warnings:
        'Curve inverted Feb 2000; the NYSE A/D line had peaked in April '
        '1998 — a two-year divergence; record insider selling; record margin '
        'debt.',
    inflation: '3.4% — contained throughout.',
    bonds:
        '10-year 6.8% → 3.6%; Fed 6.5% → 1.25%. Treasuries hedged perfectly.',
    recession: 'Yes — mild (Mar–Nov 2001).',
    recovery:
        'S&P: 7.2 years (touched May 2007, durable 2013). Nasdaq: 15.1 years '
        '(Apr 23, 2015).',
    precedingBull: 'Oct 1990 – Mar 2000: 9.5 years, +417%.',
    aftermath: 'Reg FD (2000); Sarbanes–Oxley (2002); analyst settlements.',
    signalsPresent: [
      'index_ath', 'valuation', 'leverage', 'spec_tier', 'fed', 'curve',
      'breadth',
    ],
  ),
  CrisisRecord(
    name: 'The Global Financial Crisis',
    years: '2007–2009',
    index: 'S&P 500',
    peak: 'Oct 9, 2007 · 1,565.15',
    trough: 'Mar 9, 2009 · 676.53',
    drawdown: '−56.8%',
    declineLength: '17 months',
    leadUp:
        'Housing peaked in 2006; financials topped in FEBRUARY 2007 — eight '
        'months before the index made a marginal new high on gross breadth '
        'divergence. Credit spreads had been widening since June; BNP froze '
        'its funds Aug 9, two months before the equity peak.',
    trigger:
        'A sequence, not an event: New Century (Apr 07) → BNP freeze (Aug 07) '
        '→ Bear Stearns (Mar 08) → Lehman (Sep 15, 2008) → AIG → money funds '
        'breaking the buck.',
    causes:
        'A housing/credit bubble carried through a securitization chain at '
        '30:1 bank leverage; the stress lived in opaque vehicles priced far '
        'from their marks.',
    warnings:
        'Curve inverted from 2006; housing rolling for a year; financials '
        'down first; ABX collapsing; spreads turning off record June tights.',
    inflation:
        '4.1% (2007); oil \$147 pushed headline to 5.6% (Jul 2008) → deflation '
        '−0.4% (2009).',
    bonds:
        '10-year 5.3% → 2.1%; Fed 5.25% → 0. Treasuries were the great hedge; '
        'high-yield spreads reached ≈2,000bp — credit was crushed.',
    recession: 'Yes — Dec 2007 – Jun 2009, the worst since the 1930s.',
    recovery: '5.5 years — Mar 28, 2013.',
    precedingBull: 'Oct 2002 – Oct 2007: 5.0 years, +101%.',
    aftermath: 'TARP; seven years of ZIRP; QE 1–3; Dodd–Frank; Basel III.',
    signalsPresent: [
      'index_ath', 'leverage', 'fed', 'curve', 'public_credit',
      'private_credit', 'breadth',
    ],
  ),
  CrisisRecord(
    name: 'The COVID crash',
    years: '2020',
    index: 'S&P 500',
    peak: 'Feb 19, 2020 · 3,386.15',
    trough: 'Mar 23, 2020 · 2,237.40',
    drawdown: '−33.9%',
    declineLength: '23 trading days — the fastest ≥30% decline ever',
    leadUp:
        'An all-time high on Feb 19 with the epidemic already public (Wuhan '
        'locked down Jan 23) — pure complacency about an exogenous shock. '
        'Breadth and credit were clean into the top.',
    trigger:
        'The pandemic, compounded by the Mar 8 Saudi–Russia oil-price war. '
        'Circuit breakers tripped four times in eight sessions; VIX closed at '
        '82.69.',
    causes:
        'Exogenous shock into the longest expansion ever; the Treasury '
        'basis-trade unwind briefly seized the world\'s safest market.',
    warnings:
        'The curve had inverted in Aug 2019 (a recession signal whose cause '
        'arrived from outside); the epidemic was public four weeks before the '
        'peak.',
    inflation: '1.4% → 0.1% (May 2020); the stimulus seeded 2021\'s surge.',
    bonds:
        '10-year 1.9% → 0.31% record low; unlimited QE announced on the exact '
        'trough day (Mar 23).',
    recession: 'Yes — two months: the deepest and shortest ever.',
    recovery: '0.5 years — Aug 18, 2020, the fastest ever.',
    precedingBull:
        'Mar 2009 – Feb 2020: 131 months, +401% — the longest on record.',
    aftermath:
        'The unlimited-QE precedent; ~\$5T fiscal; the retail-options era.',
    signalsPresent: ['index_ath', 'curve'],
  ),
  CrisisRecord(
    name: 'The inflation bear',
    years: '2022',
    index: 'S&P 500',
    peak: 'Jan 3, 2022 · 4,796.56',
    trough: 'Oct 12, 2022 · 3,577.03',
    drawdown: 'S&P −25.4% · Nasdaq −35.6%',
    declineLength: '9.3 months',
    leadUp:
        '2021 gained +27% with narrowing breadth; the speculative tier (ARKK, '
        'SPACs, memes) topped in FEBRUARY 2021 — eleven months before the '
        'index. Margin debt set its record (\$935B) in Oct 2021; CAPE 38.6, '
        'second only to 2000.',
    trigger:
        'Inflation 7% → 9.1% and the fastest Fed hiking since 1980 (0 → 4.25% '
        'in nine months), plus QT and the Ukraine invasion (Feb 24).',
    causes:
        '≈\$5T of pandemic stimulus meeting broken supply chains; a duration '
        'crash that hit bonds AND stocks.',
    warnings:
        'The spec tier was −50% before the index peaked; margin debt at '
        'records; the Fed pivot telegraphed in Nov 2021.',
    inflation: '7.0% (Dec 2021) → 9.1% (Jun 2022) — a 40-year high.',
    bonds:
        'The anomaly: 10-year 1.5% → 4.25%; long Treasuries −30%+ — the worst '
        'bond year on record. The worst 60/40 year since 1937. Nothing hedged.',
    recession: 'No (through 2024).',
    recovery: '2.0 years — Jan 19, 2024.',
    precedingBull: 'Mar 2020 – Jan 2022: 21 months, +114%.',
    aftermath:
        'The rate shock\'s aftershock: SVB and the regional banks failed in '
        'Mar 2023 → the BTFP facility.',
    signalsPresent: ['index_ath', 'valuation', 'leverage', 'spec_tier', 'fed'],
  ),
];
