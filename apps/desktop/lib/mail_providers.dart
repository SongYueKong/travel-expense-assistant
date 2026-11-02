class MailProvider {
  final String id, label, host;
  final List<String> domains;
  const MailProvider(this.id, this.label, this.host, this.domains);
}

const mailProviders = [
  MailProvider(
      'qq', 'QQ / Foxmail 个人邮箱', 'imap.qq.com', ['qq.com', 'foxmail.com']),
  MailProvider('163', '163 个人邮箱', 'imap.163.com', ['163.com']),
  MailProvider('126', '126 个人邮箱', 'imap.126.com', ['126.com']),
  MailProvider('yeah', '网易 yeah 邮箱', 'imap.yeah.net', ['yeah.net']),
  MailProvider('139', '移动 139 邮箱', 'imap.139.com', ['139.com']),
  MailProvider('sina', '新浪邮箱（sina.com）', 'imap.sina.com', ['sina.com']),
  MailProvider('sina_cn', '新浪邮箱（sina.cn）', 'imap.sina.cn', ['sina.cn']),
  MailProvider('aliyun', '阿里个人邮箱', 'imap.aliyun.com', ['aliyun.com']),
];
MailProvider? providerById(String id) =>
    mailProviders.where((p) => p.id == id).firstOrNull;
String? providerForAccount(String account) {
  final domain = account.trim().toLowerCase().split('@').last;
  return mailProviders.where((p) => p.domains.contains(domain)).firstOrNull?.id;
}

bool validMailbox(String provider, String account) {
  final value = account.trim().toLowerCase();
  return value.length <= 254 &&
      value.codeUnits.every((c) => c >= 33 && c < 127) &&
      RegExp(r'^[^\s@]+@[^\s@]+$').hasMatch(value) &&
      providerById(provider)?.domains.contains(value.split('@').last) == true;
}
