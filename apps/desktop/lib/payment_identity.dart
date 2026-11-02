import 'dart:io';
import 'dart:convert';
import 'services.dart';

typedef MaterialData = Map<String, dynamic>;

bool isScreenshot(MaterialData m) =>
    RegExp(r'\.(png|jpe?g)$', caseSensitive: false).hasMatch(m['path'] ?? '');

String identityPath(String path) {
  final key = File(path).absolute.path.replaceAll('\\', '/');
  return Platform.isWindows ? key.toLowerCase() : key;
}

/// 仅使用明确身份依据；同金额、同时间或图片相似不能证明是同一笔支付。
Set<String> materialIdentities(MaterialData m) => {
      if (m['path'] is String) 'path:${identityPath(m['path'])}',
      if (m['hash'] is String) 'hash:${m['hash']}',
      if (isScreenshot(m)) ...[
        for (final hash in (m['paymentDuplicateHashes'] as List? ?? []))
          'hash:$hash',
        for (final hash in (m['paymentDuplicatePixelHashes'] as List? ?? []))
          'pixels:$hash',
        if (m['imagePixelHash'] is String) 'pixels:${m['imagePixelHash']}',
        if (m['ocr']?['paymentTransactionId'] is String)
          'transaction:${m['ocr']['transactionIdKind'] ?? 'transaction'}:${m['ocr']['paymentTransactionId']}',
      ],
    };

/// 为旧任务补全图像身份，读取缓存 OCR 原文，不改写金额、时间或人工关联。
Future<List<MaterialData>> loadPaymentIdentities(
    ProcessingClient engine, List<MaterialData> records) async {
  final result = <MaterialData>[];
  for (final m in records) {
    var upgraded = {...m};
    if (isScreenshot(m) && m['paymentIdentityVersion'] != 2) {
      try {
        final identity = MaterialData.from(await engine.call('image.identity',
            {'path': m['path'], if (m['ocr'] != null) 'ocr': m['ocr']}));
        upgraded = {
          ...m,
          'imagePixelHash': identity['imagePixelHash'],
          'paymentIdentityVersion': 2,
          'paymentContentEvidence': identity['paymentContentEvidence'],
          if (m['ocr'] != null)
            'ocr': {
              ...MaterialData.from(m['ocr']),
              if (identity['paymentTransactionId'] != null)
                'paymentTransactionId': identity['paymentTransactionId'],
              if (identity['transactionIdKind'] != null)
                'transactionIdKind': identity['transactionIdKind']
            }
        };
      } catch (_) {/* 原件不可读时保留已有身份及关联。 */}
    }
    result.add(upgraded);
  }
  return result;
}

class MaterialIdentityIndex {
  final Map<String, MaterialData> _owners = {};
  final List<MaterialData> _contents = [];
  MaterialIdentityIndex([Iterable<MaterialData> records = const []]) {
    for (final record in records) {
      add(record);
    }
  }
  MaterialData? find(MaterialData record) {
    for (final key in materialIdentities(record)) {
      if (_owners.containsKey(key)) return _owners[key];
    }
    for (final owner in _contents) {
      if (samePaymentContent(owner, record)) return owner;
    }
    return null;
  }

  /// 为重复项也记录别名，后续再次导入同一截图无需依赖 OCR 是否成功。
  MaterialData add(MaterialData record) {
    final owner = find(record) ?? record;
    for (final key in materialIdentities(record)) {
      _owners[key] = owner;
    }
    if (identical(owner, record) && record['paymentContentEvidence'] != null) {
      _contents.add(record);
    }
    return owner;
  }
}

/// 无交易单号时，秒级时间、金额、商户说明、付款方式都相同，且每个字段的字形和正文图像吻合才去重。
bool samePaymentContent(MaterialData a, MaterialData b) {
  if (!isScreenshot(a) ||
      !isScreenshot(b) ||
      a['ocr']?['paymentTransactionId'] != null ||
      b['ocr']?['paymentTransactionId'] != null) {
    return false;
  }
  final x = a['paymentContentEvidence'], y = b['paymentContentEvidence'];
  if (x is! Map || y is! Map || x['version'] != 1 || y['version'] != 1) {
    return false;
  }
  try {
    final xf = x['facts'] as Map,
        yf = y['facts'] as Map,
        xr = x['rows'] as Map,
        yr = y['rows'] as Map;
    if (xf['platform'] != 'didi' ||
        xf['cents'] is! int ||
        xf['cents'] <= 0 ||
        ['paid', 'ride', 'description', 'method'].any(
            (field) => xf[field] is! String || (xf[field] as String).isEmpty)) {
      return false;
    }
    if (xf.length != yf.length ||
        xf.keys.any((k) => xf[k] != yf[k]) ||
        xr.length != yr.length) {
      return false;
    }
    for (final field in [
      'amount',
      'paymentDateTime',
      'rideDateTime',
      'description',
      'method'
    ]) {
      if (!xr.containsKey(field) || !yr.containsKey(field)) return false;
    }
    for (final field in xr.keys) {
      if (!yr.containsKey(field)) return false;
      final p = base64Decode(xr[field]['bits']),
          q = base64Decode(yr[field]['bits']);
      if (p.length != 1536 || q.length != p.length) return false;
      var changed = 0;
      for (var i = 0; i < p.length; i++) {
        var v = p[i] ^ q[i];
        while (v != 0) {
          changed++;
          v &= v - 1;
        }
      }
      final ink = (xr[field]['ink'] as int) < (yr[field]['ink'] as int)
          ? xr[field]['ink'] as int
          : yr[field]['ink'] as int;
      if (ink < 30 || changed > (ink * .005 < 3 ? 3 : ink * .005)) return false;
    }
    final p = base64Decode(x['body']), q = base64Decode(y['body']);
    if (p.length != 2048 || q.length != p.length) return false;
    var difference = 0;
    for (var i = 0; i < p.length; i++) {
      difference += (p[i] - q[i]).abs();
    }
    return difference <= p.length; // 平均灰度差最多 1/255，非“图片大致相似”即可判重。
  } catch (_) {
    return false;
  }
}
