/// 内置模型（由 SLIPE 后端下发）
class BuiltinLlmModel {
  final String id;
  final String name;
  final String description;
  final double multiplier;
  final int tokensPerCredit;
  final bool isDefault;

  const BuiltinLlmModel({
    required this.id,
    required this.name,
    this.description = '',
    this.multiplier = 1,
    this.tokensPerCredit = 1000,
    this.isDefault = false,
  });

  factory BuiltinLlmModel.fromJson(Map<String, dynamic> json) {
    return BuiltinLlmModel(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      description: (json['description'] ?? '').toString(),
      multiplier: (json['multiplier'] as num?)?.toDouble() ?? 1,
      tokensPerCredit: (json['tokensPerCredit'] as num?)?.toInt() ?? 1000,
      isDefault: json['isDefault'] == true,
    );
  }
}

/// 一条积分流水
class CreditLogEntry {
  final DateTime? time;
  final String type;
  final int amount;
  final int balance;
  final String note;

  const CreditLogEntry({
    this.time,
    required this.type,
    required this.amount,
    required this.balance,
    this.note = '',
  });

  factory CreditLogEntry.fromJson(Map<String, dynamic> json) {
    return CreditLogEntry(
      time: DateTime.tryParse((json['ts'] ?? '').toString())?.toLocal(),
      type: (json['type'] ?? '').toString(),
      amount: (json['amount'] as num?)?.toInt() ?? 0,
      balance: (json['balance'] as num?)?.toInt() ?? 0,
      note: (json['note'] ?? '').toString(),
    );
  }

  String get typeLabel {
    switch (type) {
      case 'register_bonus':
        return '注册赠送';
      case 'checkin':
        return '每日签到';
      case 'redeem':
        return '激活码充值';
      case 'llm_usage':
        return 'AI 调用';
      case 'admin_adjust':
        return '后台调整';
      default:
        return '积分变动';
    }
  }
}

/// 充值套餐
class CreditPlan {
  final String id;
  final String name;
  final int credits;
  final double price;
  final String description;
  final String badge;

  const CreditPlan({
    required this.id,
    required this.name,
    required this.credits,
    required this.price,
    this.description = '',
    this.badge = '',
  });

  factory CreditPlan.fromJson(Map<String, dynamic> json) {
    return CreditPlan(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      credits: (json['credits'] as num?)?.toInt() ?? 0,
      price: (json['price'] as num?)?.toDouble() ?? 0,
      description: (json['description'] ?? '').toString(),
      badge: (json['badge'] ?? '').toString(),
    );
  }
}

/// 计费口径
class BillingPricing {
  final int tokensPerCredit;
  final int initialCredits;
  final int checkinReward;

  const BillingPricing({
    this.tokensPerCredit = 1000,
    this.initialCredits = 500,
    this.checkinReward = 100,
  });

  factory BillingPricing.fromJson(Map<String, dynamic> json) {
    return BillingPricing(
      tokensPerCredit: (json['tokensPerCredit'] as num?)?.toInt() ?? 1000,
      initialCredits: (json['initialCredits'] as num?)?.toInt() ?? 500,
      checkinReward: (json['checkinReward'] as num?)?.toInt() ?? 100,
    );
  }
}

class BillingInfo {
  final List<CreditPlan> plans;
  final BillingPricing pricing;

  const BillingInfo({this.plans = const [], this.pricing = const BillingPricing()});
}
