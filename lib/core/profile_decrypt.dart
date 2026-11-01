import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// 机场加密的订阅（响应头 subscription-encryption: true）。
/// AES-128-CBC，密钥是密码的 MD5，IV 是密文开头 16 字节，整体 base64 编码。
class ProfileDecrypt {
  static const int _ivLength = 16;

  /// 密码不对或内容不是这种格式时返回 null
  static String? decrypt(String password, String content) {
    if (password.isEmpty || content.isEmpty) return null;

    final Uint8List raw;
    try {
      raw = base64.decode(content.replaceAll(RegExp(r'\s'), ''));
    } on FormatException {
      return null;
    }
    if (raw.length <= _ivLength) return null;

    final key = MD5Digest().process(Uint8List.fromList(utf8.encode(password)));
    final cipher = PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()))
      ..init(
          false,
          PaddedBlockCipherParameters<CipherParameters, CipherParameters>(
              ParametersWithIV<KeyParameter>(KeyParameter(key), raw.sublist(0, _ivLength)), null));

    try {
      return utf8.decode(cipher.process(raw.sublist(_ivLength)));
    } on ArgumentError {
      return null;
    } on StateError {
      return null;
    } on FormatException {
      return null;
    }
  }
}
