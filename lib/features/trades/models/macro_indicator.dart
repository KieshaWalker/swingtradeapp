class MacroIndicator {
  final String id;
  final String userId;
  final String name;
  final int weight; // -100 to +100 (signed %)
  final DateTime createdAt;

  const MacroIndicator({
    required this.id,
    required this.userId,
    required this.name,
    required this.weight,
    required this.createdAt,
  });

  bool get isBullish => weight >= 0;

  factory MacroIndicator.fromJson(Map<String, dynamic> json) => MacroIndicator(
        id: json['id'] as String,
        userId: json['user_id'] as String,
        name: json['name'] as String,
        weight: json['weight'] as int,
        createdAt: DateTime.parse(json['created_at'] as String),
      );
}
