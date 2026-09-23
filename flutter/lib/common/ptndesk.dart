import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';
import 'package:uuid/uuid.dart';

import 'package:flutter_hbb/models/platform_model.dart';

// Customer-locked RustDesk client (PTNDesk). The client is pointed at our infra
// and must enroll with a 5-digit labcode before it is admitted by hbbs.
//
// Baked in: our rendezvous server + key, the verify API URL, and the RSA public
// key used to encrypt the /verify payload (the private half lives in RN.Licensing).

const String kPtnServer = 'rd.ptnapi.ir';
const String kPtnKey = 'ftPzQdJOdXfTZRpfx5qaPsWMg9SFdqFbyOQEb5iSsNw=';
const String kPtnApiServer = 'https://verify.ptnapi.ir';
const String kPtnVerifyUrl = 'https://verify.ptnapi.ir/rustdesk/verify';
const String kPtnHeartbeatUrl = 'https://verify.ptnapi.ir/rustdesk/heartbeat';

// RSA public modulus (base64, big-endian) of RustDeskAuth; exponent = 65537.
const String kPtnPubModulusB64 =
    'mCwUyP/Rol1tQkduhzxtMXHFiawWRWPkMlghz6Hldjtw/IlQPxAmN52KH7BjTGp6xObSxemmkfn9JQI5B6FhPrjjT204Wck3Ecysk8Q8xktIZFNw7zOCPLgSIzdipaYpSTydejqtlWOExjivrtw9Avu6yY/ER+bYW+qQhIwRPgoQet7lDLenNXiyfPbcX2q6Xsb7ZVHIx8T3tRx270hRtskHmB7z7cWs0asN3rXt1dU6CokNL46f20+ugbZ6vEpWCcO0DlBryfjoAYEm0Mc5FvuoeE/i5DeQf2gU9kq4ZqJZDXc5hdGKNmG5jC+sobgFJx8OkJOIc052eu/paWQaOQ==';

// Read on the Rust side (core_main) too, so keep the literal key in sync there.
const String kPtnRoleOption = 'ptndesk-role';

// Per-process enrollment token: the labcode is re-asked on every fresh launch.
// Minimizing or closing to tray keeps the process alive (no re-prompt); a full
// exit clears this, so the next launch prompts for the labcode again.
String _ptnSessionToken = '';
// Lab display name from the last successful /verify; shown on the home page.
String _ptnLabName = '';

BigInt _bytesToBigInt(Uint8List bytes) {
  var result = BigInt.zero;
  for (final b in bytes) {
    result = (result << 8) + BigInt.from(b);
  }
  return result;
}

Uint8List _rsaOaepSha1Encrypt(Uint8List data) {
  final pub = RSAPublicKey(
      _bytesToBigInt(base64.decode(kPtnPubModulusB64)), BigInt.from(65537));
  // Default OAEPEncoding uses SHA-1 for hash + MGF1 — matches C# OaepSHA1.
  final cipher = OAEPEncoding(RSAEngine())
    ..init(true, PublicKeyParameter<RSAPublicKey>(pub));
  return cipher.process(data);
}

// Force the client onto our server/key every launch (locks the config).
Future<void> ptndeskPresetConfig() async {
  // Default the UI to Persian on first run; leave a later user choice alone.
  if (bind.mainGetLocalOption(key: 'lang').isEmpty) {
    await bind.mainSetLocalOption(key: 'lang', value: 'fa');
  }
  await bind.mainSetOption(key: 'custom-rendezvous-server', value: kPtnServer);
  await bind.mainSetOption(key: 'relay-server', value: kPtnServer);
  await bind.mainSetOption(key: 'key', value: kPtnKey);
  await bind.mainSetOption(key: 'api-server', value: kPtnApiServer);
  ptndeskStartHeartbeat();
}

Timer? _ptnHeartbeatTimer;

// Ping the licensing server every 30s while enrolled. The server renews this
// device's allow-row to the current support end, or revokes it (and hbbs then
// denies the next connection) if support has lapsed while the app stayed open.
// It also refreshes LastSeen so the back office sees the customer as online.
void ptndeskStartHeartbeat() {
  _ptnHeartbeatTimer?.cancel();
  _ptnHeartbeatTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
    if (!ptndeskIsEnrolled()) return;
    try {
      final body = jsonEncode({
        'RustDeskId': await bind.mainGetMyId(),
        'DeviceToken': _ptnSessionToken,
      });
      await bind.ptndeskPost(url: kPtnHeartbeatUrl, body: body);
    } catch (_) {
      // Best-effort: the allow-row's support-date expiry still bounds access.
    }
  });
}

bool ptndeskIsEnrolled() => _ptnSessionToken.isNotEmpty;

String ptndeskDeviceToken() => _ptnSessionToken;

String ptndeskLabName() => _ptnLabName;

/// Enrolls with a labcode. Returns '' on success, otherwise a user-facing error.
Future<String> ptndeskEnroll(String labCode) async {
  final code = int.tryParse(labCode.trim());
  if (code == null || code <= 0) return 'کد آزمایشگاه نامعتبر است';

  String respBody;
  try {
    // mainGetMyId/mainGetVersion are async — they must be awaited before
    // encoding, or the payload holds unresolved Futures and jsonEncode throws.
    final payload = jsonEncode({
      'LabCode': code,
      'RustDeskId': await bind.mainGetMyId(),
      'Hostname': _hostname(),
      'AppVersion': await bind.mainGetVersion(),
      'TimestampUtc': DateTime.now().toUtc().toIso8601String(),
      'Nonce': const Uuid().v4(),
    });
    final enc = _rsaOaepSha1Encrypt(Uint8List.fromList(utf8.encode(payload)));
    final body = jsonEncode({'payload': base64.encode(enc), 'ips': ''});
    // POST via Rust (reqwest): Dart's dart:io TLS crashes on Windows 7.
    respBody = await bind.ptndeskPost(url: kPtnVerifyUrl, body: body);
  } catch (e) {
    return 'اتصال به سرور ممکن نشد';
  }

  if (respBody.isEmpty) return 'اتصال به سرور ممکن نشد';
  Map<String, dynamic>? data;
  try {
    data = (jsonDecode(respBody)['data']) as Map<String, dynamic>?;
  } catch (_) {}
  if (data == null) return 'پاسخ نامعتبر از سرور';
  if (data['ok'] != true) return (data['message'] ?? 'مجوز صادر نشد').toString();

  _ptnSessionToken = (data['deviceToken'] ?? '').toString();
  // Lab names may carry a "*suffix" that must not be shown; keep the part before it.
  _ptnLabName = (data['labName'] ?? '').toString().split('*').first.trim();
  // Role decides the incoming-only lock at next launch (see core_main.rs).
  await bind.mainSetLocalOption(
      key: kPtnRoleOption, value: (data['role'] ?? 'customer').toString());
  final server = (data['server'] ?? kPtnServer).toString();
  final key = (data['key'] ?? kPtnKey).toString();
  await bind.mainSetOption(key: 'custom-rendezvous-server', value: server);
  await bind.mainSetOption(key: 'relay-server', value: server);
  await bind.mainSetOption(key: 'key', value: key);
  return '';
}

String _hostname() {
  try {
    return Platform.localHostname;
  } catch (_) {
    return '';
  }
}
