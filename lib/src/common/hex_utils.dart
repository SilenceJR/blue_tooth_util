import 'dart:typed_data';

/// 将字节数组转为十六进制字符串。
///
/// [bytes] 为待转换字节；[separator] 为字节之间的分隔符，默认空格。
String bytesToHex(Iterable<int> bytes, {String separator = ' '}) {
  return bytes
      .map((value) => value.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join(separator);
}

/// 将十六进制字符串转为字节数组。
///
/// [hex] 可包含空格、换行等非十六进制字符，解析时会自动忽略。
Uint8List hexToBytes(String hex) {
  final clean = hex.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
  if (clean.length.isOdd) {
    throw const FormatException('Hex string length must be even');
  }
  final bytes = <int>[];
  for (var index = 0; index < clean.length; index += 2) {
    bytes.add(int.parse(clean.substring(index, index + 2), radix: 16));
  }
  return Uint8List.fromList(bytes);
}
