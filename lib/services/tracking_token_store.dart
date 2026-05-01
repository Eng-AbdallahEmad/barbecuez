import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class TrackingTokenStore {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );
  static const _key = 'tracking_tokens_map';

  // Validation matches src/lib/trackedOrders.ts
  static final _orderRe = RegExp(r'^[A-Z0-9-]{4,24}$', caseSensitive: false);
  static final _tokenRe = RegExp(r'^[A-Za-z0-9._-]{20,128}$');

  static Future<Map<String, String>> readAll() async {
    try {
      final raw = await _storage.read(key: _key);
      if (raw == null || raw.isEmpty) return {};
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return decoded.map((k, v) => MapEntry(k.toString(), v.toString()));
    } catch (_) {
      return {};
    }
  }

  static Future<String?> get(String orderNumber) async {
    if (!_orderRe.hasMatch(orderNumber)) return null;
    final all = await readAll();
    return all[orderNumber];
  }

  static Future<void> set(String orderNumber, String token) async {
    if (!_orderRe.hasMatch(orderNumber)) return;
    if (!_tokenRe.hasMatch(token)) return;
    final all = await readAll();
    all[orderNumber] = token;
    // حد أقصى 50 طلب — احذف الأقدم
    if (all.length > 50) {
      final keys = all.keys.toList()..sort();
      for (var i = 0; i < all.length - 50; i++) {
        all.remove(keys[i]);
      }
    }
    await _storage.write(key: _key, value: jsonEncode(all));
  }

  static Future<void> remove(String orderNumber) async {
    final all = await readAll();
    all.remove(orderNumber);
    await _storage.write(key: _key, value: jsonEncode(all));
  }
}
