import 'dart:typed_data';

import '../common/ble_failure.dart';
import '../common/result.dart';

/// 智能戒指协议命令字。
enum RingCommand {
  /// 联调测试命令，设备会原样回显 payload。
  ping(0x0001, 'PING'),

  /// 查询设备信息。
  deviceInfo(0x0101, 'Device info'),

  /// 查询电量。
  battery(0x0102, 'Battery'),

  /// 开关实时运动上报。
  sportRealtimeSwitch(0x0108, 'Realtime sport switch'),

  /// 软断开蓝牙连接。
  softDisconnect(0x0109, 'Soft disconnect'),

  /// 屏幕方向翻转。
  screenFlip(0x010A, 'Screen flip'),

  /// 寻找戒指。
  findRing(0x010B, 'Find ring'),

  /// 确认并清除某天历史赞念数据。
  clearZikrHistoryDay(0x010C, 'Clear zikr history day'),

  /// 设置或接收息屏时间。
  screenOffTime(0x010D, 'Screen off time'),

  /// 设置设备时间。
  setTime(0x0201, 'Set time'),

  /// 设备主动上报实时运动数据。
  sportRealtimeReport(0x0303, 'Realtime sport report'),

  /// 设备主动上报按键计数。
  buttonCountReport(0x0304, 'Button count report'),

  /// 设备主动上报电量变化。
  batteryReport(0x0305, 'Battery report'),

  /// 设备主动上报赞念小时桶数据。
  zikrHourlyReport(0x0306, 'Zikr hourly report'),

  /// 查询设备当前时间。
  queryTime(0x0502, 'Query time');

  /// [value] 为 16-bit 命令字；[label] 为调试日志显示名称。
  const RingCommand(this.value, this.label);

  /// 16-bit 命令字。
  final int value;

  /// 调试日志显示名称。
  final String label;

  /// 根据 16-bit 命令字查找枚举；未知命令返回 `null`。
  static RingCommand? fromValue(int value) {
    for (final command in values) {
      if (command.value == value) return command;
    }
    return null;
  }
}

/// 设备错误帧中的错误码。
enum RingDeviceError {
  /// CRC 校验失败。
  crc(0x01, 'CRC check failed'),

  /// 未知命令。
  unknownCommand(0x02, 'Unknown command'),

  /// payload 长度非法。
  badLength(0x03, 'Bad payload length'),

  /// 参数越界。
  outOfRange(0x04, 'Parameter out of range'),

  /// 当前设备状态不允许该操作。
  badState(0x05, 'Invalid device state'),

  /// 命令需要加密后才能执行。
  needEncrypt(0x06, 'Encryption required');

  /// [code] 为设备错误码；[message] 为错误说明。
  const RingDeviceError(this.code, this.message);

  /// 设备返回的 1 字节错误码。
  final int code;

  /// 错误说明。
  final String message;

  /// 根据设备错误码查找枚举；未知错误返回 `null`。
  static RingDeviceError? fromCode(int code) {
    for (final error in values) {
      if (error.code == code) return error;
    }
    return null;
  }
}

/// 智能戒指 GATT 与连接参数常量。
class RingProtocol {
  const RingProtocol._();

  /// 主服务 UUID，16-bit 形式。
  static const serviceUuid = '56ff';

  /// App 写命令的特征 UUID。
  static const writeCharacteristicUuid = '33f3';

  /// 设备 Notify 响应/上报的特征 UUID。
  static const notifyCharacteristicUuid = '33f4';

  /// 默认广播名称。
  static const deviceName = 'BS Ring 2';

  /// 连接后建议请求的 MTU。
  static const requestedMtu = 247;
}

/// 智能戒指 TLV 帧。
class RingFrame {
  /// [commandValue] 为 16-bit 命令字；[payload] 为帧载荷。
  const RingFrame({required this.commandValue, required this.payload});

  /// 原始 16-bit 命令字，未知命令也会保留该值。
  final int commandValue;

  /// payload 字节，不包含头、命令、长度、CRC 和尾。
  final Uint8List payload;

  /// 命令枚举；未知命令返回 `null`。
  RingCommand? get command => RingCommand.fromValue(commandValue);

  /// 是否为设备错误帧，错误帧 payload 形如 `FF <错误码>`。
  bool get isDeviceError => payload.length >= 2 && payload[0] == 0xFF;

  /// 设备错误码枚举；非错误帧返回 `null`。
  RingDeviceError? get deviceError =>
      isDeviceError ? RingDeviceError.fromCode(payload[1]) : null;
}

/// 智能戒指 TLV 帧编解码器。
class RingFrameCodec {
  const RingFrameCodec();

  static const _head0 = 0x89;
  static const _head1 = 0x56;
  static const _tail0 = 0xB5;
  static const _tail1 = 0x3A;

  /// 编码已知命令。
  ///
  /// [command] 为命令枚举；[payload] 为业务载荷，最大 240 字节。
  Uint8List encode(RingCommand command, [List<int> payload = const []]) {
    return encodeValue(command.value, payload);
  }

  /// 按原始命令字编码帧。
  ///
  /// [commandValue] 用于兼容未知或扩展命令；[payload] 为业务载荷。
  Uint8List encodeValue(int commandValue, [List<int> payload = const []]) {
    if (payload.length > 240) {
      throw ArgumentError.value(payload.length, 'payload', 'Maximum is 240');
    }
    final frame = Uint8List(14 + payload.length);
    frame[0] = _head0;
    frame[1] = _head1;
    _setUint16(frame, 2, commandValue);
    _setUint16(frame, 4, 1);
    _setUint16(frame, 6, 1);
    _setUint16(frame, 8, payload.length);
    frame.setRange(10, 10 + payload.length, payload);
    final crc = crc16Modbus(frame.sublist(2, 10 + payload.length));
    _setUint16(frame, 10 + payload.length, crc);
    frame[12 + payload.length] = _tail0;
    frame[13 + payload.length] = _tail1;
    return frame;
  }

  /// 解码完整 TLV 帧。
  ///
  /// [frame] 必须包含头、命令、包字段、payload、CRC 和尾。
  /// CRC、头尾和长度不合法时返回 [Result.failure]。
  Result<RingFrame> decode(Uint8List frame) {
    if (frame.length < 14) {
      return _invalid('Frame too short');
    }
    if (frame[0] != _head0 || frame[1] != _head1) {
      return _invalid('Invalid frame head');
    }
    if (frame[frame.length - 2] != _tail0 ||
        frame[frame.length - 1] != _tail1) {
      return _invalid('Invalid frame tail');
    }

    final commandValue = _getUint16(frame, 2);
    final totalPackets = _getUint16(frame, 4);
    final packetSeq = _getUint16(frame, 6);
    final payloadLength = _getUint16(frame, 8);
    if (totalPackets != 1 || packetSeq != 1) {
      return Result.failure(
        BleFailure(
          code: BleFailureCode.unsupported,
          message: 'Multi-packet ring frames are not supported',
        ),
      );
    }
    if (payloadLength > 240 || frame.length != 14 + payloadLength) {
      return _invalid('Invalid frame payload length');
    }

    final expectedCrc = _getUint16(frame, 10 + payloadLength);
    final actualCrc = crc16Modbus(frame.sublist(2, 10 + payloadLength));
    if (expectedCrc != actualCrc) {
      return Result.failure(
        BleFailure(
          code: BleFailureCode.crcMismatch,
          message: 'Ring frame CRC mismatch',
        ),
      );
    }

    return Result.success(
      RingFrame(
        commandValue: commandValue,
        payload: Uint8List.fromList(frame.sublist(10, 10 + payloadLength)),
      ),
    );
  }

  /// 计算 CRC16/MODBUS。
  ///
  /// [bytes] 为参与校验的字节，协议中范围为 CmdType 到 Payload。
  static int crc16Modbus(List<int> bytes) {
    var crc = 0xFFFF;
    for (final byte in bytes) {
      crc ^= byte;
      for (var bit = 0; bit < 8; bit++) {
        if ((crc & 0x0001) != 0) {
          crc = (crc >> 1) ^ 0xA001;
        } else {
          crc >>= 1;
        }
      }
    }
    return crc & 0xFFFF;
  }

  static Result<RingFrame> _invalid(String message) {
    return Result.failure(
      BleFailure(code: BleFailureCode.invalidFrame, message: message),
    );
  }

  static int _getUint16(Uint8List bytes, int offset) {
    return bytes[offset] | (bytes[offset + 1] << 8);
  }

  static void _setUint16(Uint8List bytes, int offset, int value) {
    bytes[offset] = value & 0xFF;
    bytes[offset + 1] = (value >> 8) & 0xFF;
  }
}

/// 读取小端 16-bit 无符号整数。
///
/// [bytes] 为来源字节；[offset] 为起始偏移。
int ringReadUint16(Uint8List bytes, int offset) {
  return bytes[offset] | (bytes[offset + 1] << 8);
}

/// 读取小端 32-bit 无符号整数。
///
/// [bytes] 为来源字节；[offset] 为起始偏移。
int ringReadUint32(Uint8List bytes, int offset) {
  return bytes[offset] |
      (bytes[offset + 1] << 8) |
      (bytes[offset + 2] << 16) |
      (bytes[offset + 3] << 24);
}

/// 构建设备时间 payload。
///
/// [dateTime] 会转成 Unix 秒小端 4 字节、2 字节保留位和时区编码。
Uint8List ringTimePayload(DateTime dateTime) {
  final seconds = dateTime.toUtc().millisecondsSinceEpoch ~/ 1000;
  final offset = dateTime.timeZoneOffset.inHours + 12;
  return Uint8List.fromList([
    seconds & 0xFF,
    (seconds >> 8) & 0xFF,
    (seconds >> 16) & 0xFF,
    (seconds >> 24) & 0xFF,
    0,
    0,
    offset.clamp(0, 255).toInt(),
  ]);
}

/// 解析设备时间 payload。
///
/// [payload] 为 7 字节时间结构：4 字节 Unix 秒、2 字节保留、1 字节时区编码。
DateTime ringParseTimePayload(Uint8List payload) {
  final seconds = ringReadUint32(payload, 0);
  final timezoneHour = payload[6] - 12;
  return DateTime.fromMillisecondsSinceEpoch(
    seconds * 1000,
    isUtc: true,
  ).add(Duration(hours: timezoneHour));
}
