// =============================================================================
// features/ideas/models/trade_idea.dart
// =============================================================================
import 'package:intl/intl.dart';
import '../../blotter/models/blotter_models.dart';

class TradeIdea {
  final String       id;
  final String       ticker;
  final ContractType contractType;
  final double       strike;
  final DateTime     expiryDate;
  final int          quantity;
  final double       budget;
  final double?      priceTarget;
  final String?      notes;
  final DateTime     createdAt;

  const TradeIdea({
    required this.id,
    required this.ticker,
    required this.contractType,
    required this.strike,
    required this.expiryDate,
    required this.quantity,
    required this.budget,
    this.priceTarget,
    this.notes,
    required this.createdAt,
  });

  int    get dte       => expiryDate.difference(DateTime.now()).inDays;
  bool   get isExpired => dte <= 0;
  bool   get isCall    => contractType == ContractType.call;
  String get expiryStr => DateFormat('yyyy-MM-dd').format(expiryDate);

  factory TradeIdea.fromJson(Map<String, dynamic> j) => TradeIdea(
        id:           j['id'] as String,
        ticker:       j['ticker'] as String,
        contractType: (j['contract_type'] as String) == 'call'
            ? ContractType.call
            : ContractType.put,
        strike:      (j['strike'] as num).toDouble(),
        expiryDate:   DateTime.parse(j['expiry_date'] as String),
        quantity:     j['quantity'] as int,
        budget:      (j['budget'] as num).toDouble(),
        priceTarget:  j['price_target'] != null
            ? (j['price_target'] as num).toDouble()
            : null,
        notes:       j['notes'] as String?,
        createdAt:    DateTime.parse(j['created_at'] as String),
      );

  Map<String, dynamic> toJson() => {
        'ticker':        ticker,
        'contract_type': contractType.name,
        'strike':        strike,
        'expiry_date':   expiryStr,
        'quantity':      quantity,
        'budget':        budget,
        if (priceTarget != null) 'price_target': priceTarget,
        if (notes != null)       'notes':        notes,
      };
}
