/// 订阅源的检测结果。
enum SourceHealthStatus { unknown, available, unavailable }

class SourceHealth {
  const SourceHealth({
    this.status = SourceHealthStatus.unknown,
    this.message = '',
    this.latencyMs = 0,
    this.checkedAt,
  });

  final SourceHealthStatus status;

  /// 失败原因，或成功时的简要说明。
  final String message;
  final int latencyMs;
  final DateTime? checkedAt;

  bool get isAvailable => status == SourceHealthStatus.available;
  bool get isUnavailable => status == SourceHealthStatus.unavailable;
  bool get isUnknown => status == SourceHealthStatus.unknown;

  String get label {
    switch (status) {
      case SourceHealthStatus.available:
        return '可用';
      case SourceHealthStatus.unavailable:
        return '不可用';
      case SourceHealthStatus.unknown:
        return '未检测';
    }
  }

  String get latencyLabel => latencyMs > 0 ? '${latencyMs}ms' : '';

  Map<String, dynamic> toJson() => {
        'status': status.name,
        'message': message,
        'latencyMs': latencyMs,
        'checkedAt': checkedAt?.millisecondsSinceEpoch,
      };

  factory SourceHealth.fromJson(Map<String, dynamic> json) {
    final status = SourceHealthStatus.values.firstWhere(
      (value) => value.name == json['status']?.toString(),
      orElse: () => SourceHealthStatus.unknown,
    );
    final checkedAt = json['checkedAt'];
    return SourceHealth(
      status: status,
      message: (json['message'] ?? '').toString(),
      latencyMs: json['latencyMs'] is int ? json['latencyMs'] as int : 0,
      checkedAt: checkedAt is int ? DateTime.fromMillisecondsSinceEpoch(checkedAt) : null,
    );
  }
}
