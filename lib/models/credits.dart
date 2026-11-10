/// 内置模型（由 SLIPE 后端下发）
class BuiltinLlmModel {
  final String id;
  final String name;
  final String description;
  final double multiplier;
  final int tokensPerCredit;
  final bool isDefault;

  /// 是否支持图片理解（后台勾选后允许上传图片）
  final bool supportsVision;

  const BuiltinLlmModel({
    required this.id,
    required this.name,
    this.description = '',
    this.multiplier = 1,
    this.tokensPerCredit = 1000,
    this.isDefault = false,
    this.supportsVision = false,
  });

  factory BuiltinLlmModel.fromJson(Map<String, dynamic> json) {
    return BuiltinLlmModel(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      description: (json['description'] ?? '').toString(),
      multiplier: (json['multiplier'] as num?)?.toDouble() ?? 1,
      tokensPerCredit: (json['tokensPerCredit'] as num?)?.toInt() ?? 1000,
      isDefault: json['isDefault'] == true,
      supportsVision: json['supportsVision'] == true,
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

/// 充值套餐（旧版积分包，保留用于激活码面额展示）
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

/// 会员档位（与后端 MEMBERSHIP_PLANS 对应）
class MembershipPlan {
  final String id;
  final String name;
  final String description;
  final String badge;
  final bool free;
  final int monthlyCredits;
  final int checkinReward;
  final Map<String, double> prices;

  const MembershipPlan({
    required this.id,
    required this.name,
    this.description = '',
    this.badge = '',
    this.free = false,
    this.monthlyCredits = 0,
    this.checkinReward = 0,
    this.prices = const {},
  });

  double priceFor(String cycleId) => prices[cycleId] ?? 0;

  factory MembershipPlan.fromJson(Map<String, dynamic> json) {
    final rawPrices = json['prices'];
    final prices = <String, double>{};
    if (rawPrices is Map) {
      rawPrices.forEach((key, value) {
        final price = (value as num?)?.toDouble();
        if (price != null) prices['$key'] = price;
      });
    }
    return MembershipPlan(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      description: (json['description'] ?? '').toString(),
      badge: (json['badge'] ?? '').toString(),
      free: json['free'] == true,
      monthlyCredits: (json['monthlyCredits'] as num?)?.toInt() ?? 0,
      checkinReward: (json['checkinReward'] as num?)?.toInt() ?? 0,
      prices: prices,
    );
  }
}

/// 付费周期（月付 / 季付 / 年付）
class MembershipCycle {
  final String id;
  final String name;
  final int months;
  final String unit;

  const MembershipCycle({
    required this.id,
    required this.name,
    this.months = 1,
    this.unit = '月',
  });

  factory MembershipCycle.fromJson(Map<String, dynamic> json) => MembershipCycle(
        id: (json['id'] ?? '').toString(),
        name: (json['name'] ?? '').toString(),
        months: (json['months'] as num?)?.toInt() ?? 1,
        unit: (json['unit'] ?? '月').toString(),
      );
}

/// 微信支付可用状态
class WechatPayInfo {
  final bool enabled;
  final String pageBase;

  const WechatPayInfo({this.enabled = false, this.pageBase = ''});

  factory WechatPayInfo.fromJson(Map<String, dynamic> json) => WechatPayInfo(
        enabled: json['enabled'] == true,
        pageBase: (json['pageBase'] ?? '').toString(),
      );
}

/// 微信支付订单
class WechatOrder {
  final String outTradeNo;
  final String planId;
  final String planName;
  final String cycleId;
  final String cycleName;
  final int months;
  final double amount;
  final int amountFen;
  final String status;
  final DateTime? createdAt;
  final DateTime? paidAt;
  final String transactionId;

  const WechatOrder({
    required this.outTradeNo,
    required this.planId,
    required this.planName,
    required this.cycleId,
    required this.cycleName,
    this.months = 1,
    this.amount = 0,
    this.amountFen = 0,
    this.status = 'pending',
    this.createdAt,
    this.paidAt,
    this.transactionId = '',
  });

  bool get isPaid => status == 'paid';
  bool get isClosed => status == 'closed' || status == 'failed' || status == 'mismatch';

  factory WechatOrder.fromJson(Map<String, dynamic> json) => WechatOrder(
        outTradeNo: (json['outTradeNo'] ?? '').toString(),
        planId: (json['planId'] ?? '').toString(),
        planName: (json['planName'] ?? '').toString(),
        cycleId: (json['cycleId'] ?? '').toString(),
        cycleName: (json['cycleName'] ?? '').toString(),
        months: (json['months'] as num?)?.toInt() ?? 1,
        amount: (json['amount'] as num?)?.toDouble() ?? 0,
        amountFen: (json['amountFen'] as num?)?.toInt() ?? 0,
        status: (json['status'] ?? 'pending').toString(),
        createdAt: DateTime.tryParse((json['createdAt'] ?? '').toString()),
        paidAt: DateTime.tryParse((json['paidAt'] ?? '').toString()),
        transactionId: (json['transactionId'] ?? '').toString(),
      );
}

/// 当前生效的会员信息
class MembershipInfo {
  final String planId;
  final String planName;
  final bool active;
  final DateTime? expiresAt;
  final int monthlyCredits;
  final int checkinReward;

  const MembershipInfo({
    this.planId = 'personal',
    this.planName = 'Personal',
    this.active = false,
    this.expiresAt,
    this.monthlyCredits = 0,
    this.checkinReward = 0,
  });

  factory MembershipInfo.fromJson(Map<String, dynamic> json) => MembershipInfo(
        planId: (json['planId'] ?? 'personal').toString(),
        planName: (json['planName'] ?? 'Personal').toString(),
        active: json['active'] == true,
        expiresAt: DateTime.tryParse((json['expiresAt'] ?? '').toString()),
        monthlyCredits: (json['monthlyCredits'] as num?)?.toInt() ?? 0,
        checkinReward: (json['checkinReward'] as num?)?.toInt() ?? 0,
      );
}

class BillingInfo {
  final List<MembershipPlan> plans;
  final List<MembershipCycle> cycles;
  final List<CreditPlan> creditPlans;
  final BillingPricing pricing;
  final WechatPayInfo wechatPay;

  const BillingInfo({
    this.plans = const [],
    this.cycles = const [],
    this.creditPlans = const [],
    this.pricing = const BillingPricing(),
    this.wechatPay = const WechatPayInfo(),
  });
}
