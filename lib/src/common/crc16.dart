/// 计算 CRC-16/MODBUS 反射多项式 `0xA001`。
///
/// [seed] 由调用协议决定：戒指业务帧使用 `0xFFFF`，`.rota` 使用 `0`。
int bleCrc16Modbus(Iterable<int> bytes, {required int seed}) {
  var crc = seed & 0xFFFF;
  for (final byte in bytes) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = crc & 1 != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1;
    }
  }
  return crc & 0xFFFF;
}
