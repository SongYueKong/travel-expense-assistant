import 'mail_providers.dart';

class MailboxIdentity {
  final String provider, account;
  const MailboxIdentity._(this.provider, this.account);
  factory MailboxIdentity(String provider, String account) {
    final normalized = account.trim().toLowerCase();
    if (!validMailbox(provider, normalized)) {
      throw const FormatException('邮箱地址与所选服务商不符，请填写完整邮箱地址');
    }
    return MailboxIdentity._(provider, normalized);
  }
  factory MailboxIdentity.fromJson(Map<String, dynamic> value) {
    if (value['account'] is! String ||
        (value['provider'] != null && value['provider'] is! String)) {
      throw const FormatException('邮箱设置格式无效');
    }
    return MailboxIdentity(
        value['provider'] ??
            (providerForAccount(value['account']) ?? 'unknown'),
        value['account']);
  }
  Map<String, String> toJson() => {'provider': provider, 'account': account};
}

abstract interface class MailboxPreferences {
  Future<MailboxIdentity?> loadDefaultMailbox();
  Future<void> saveDefaultMailbox(MailboxIdentity mailbox);
}

/// 首次升级时从历史导入记录恢复最近使用的账号；只提取服务商和邮箱。
MailboxIdentity? mostRecentMailbox(List<Map<String, dynamic>> tasks) {
  MailboxIdentity? result;
  DateTime? latest;
  for (final task in tasks) {
    for (final record in (task['mailHistory'] as List? ?? []).reversed) {
      if (record is! Map) continue;
      try {
        final identity =
            MailboxIdentity.fromJson(Map<String, dynamic>.from(record));
        final time = DateTime.tryParse(
            record['importedAt'] is String ? record['importedAt'] : '');
        if (result == null ||
            (time != null && (latest == null || time.isAfter(latest)))) {
          result = identity;
          latest = time;
        }
      } on FormatException {
        continue;
      }
    }
  }
  return result;
}
