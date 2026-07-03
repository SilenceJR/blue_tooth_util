import 'dart:typed_data';

import '../common/ble_failure.dart';
import '../common/hex_utils.dart';
import 'ring_protocol.dart';

/// 两段式命令的执行阶段。
enum RingActionPhase {
  /// 空闲状态。
  idle,

  /// App 已写出命令，正在等待设备确认。
  sending,

  /// 设备已受理命令，但还未真正执行完成。
  accepted,

  /// 设备已返回 DONE，动作完成。
  done,

  /// 命令发送、受理或等待 DONE 过程中失败。
  failed,
}

/// 两段式命令状态。
///
/// 当前用于屏幕翻转和寻找戒指，UI 可据此禁用按钮或显示执行中。
class RingActionState {
  /// [command] 为正在执行的命令；[phase] 为执行阶段。
  ///
  /// [status] 为设备返回的状态字节，例如 `0x01` 已受理、`0x02` DONE；
  /// [failure] 为失败阶段的错误原因；[message] 为适合调试 UI 展示的说明。
  const RingActionState({
    required this.command,
    required this.phase,
    this.status,
    this.failure,
    this.message,
  });

  /// 正在执行的命令。
  final RingCommand command;

  /// 命令当前阶段。
  final RingActionPhase phase;

  /// 设备返回的原始状态字节，发送中或本地失败时为空。
  final int? status;

  /// 失败详情，仅 [RingActionPhase.failed] 阶段有值。
  final BleFailure? failure;

  /// 调试说明，用于 example 展示状态变化原因。
  final String? message;
}

/// 收发帧日志。
class RingFrameLog {
  /// 创建帧日志。
  ///
  /// [direction] 为 `TX` 或 `RX`；[timestamp] 为收发时间；
  /// [commandValue] 为命令字；[hex] 为完整帧十六进制。
  const RingFrameLog({
    required this.direction,
    required this.timestamp,
    required this.commandValue,
    required this.hex,
    this.command,
    this.description,
    this.error,
  });

  /// 收发方向，`TX` 表示 App 写出，`RX` 表示设备 Notify。
  final String direction;

  /// 日志产生时间。
  final DateTime timestamp;

  /// 原始命令字。
  final int commandValue;

  /// 已知命令枚举，未知命令为空。
  final RingCommand? command;

  /// 完整帧十六进制字符串。
  final String hex;

  /// 附加说明，例如错误描述。
  final String? description;

  /// 设备返回的错误码，非错误帧为空。
  final RingDeviceError? error;

  /// UI 日志标题，优先显示命令名称，未知命令显示十六进制命令字。
  String get title => command?.label ?? '0x${commandValue.toRadixString(16)}';
}

/// 设备信息响应。
class RingDeviceInfo {
  /// 创建设备信息。
  ///
  /// 字段来源于 `0x0101` 的 52 字节响应 payload。
  const RingDeviceInfo({
    required this.manufacturer,
    required this.model,
    required this.firmwareVersion,
    required this.hardwareVersion,
    required this.serialNumber,
    required this.protocolVersion,
    required this.color,
    required this.size,
  });

  /// 制造商名称，例如 `BUMBLE`。
  final String manufacturer;

  /// 产品型号，例如 `Ring2`。
  final String model;

  /// 固件版本，小端 16-bit 整数。
  final int firmwareVersion;

  /// 硬件版本原始字节，当前固件未定时通常为全 0。
  final String hardwareVersion;

  /// 产品序列号，前 6 字节为设备 MAC，后续为保留位。
  final String serialNumber;

  /// 蓝牙协议版本，例如 `1.1.5.0`。
  final String protocolVersion;

  /// 颜色编号，当前固件未设置时为 0。
  final int color;

  /// 尺寸编号，当前固件未设置时为 0。
  final int size;

  /// 从设备信息 payload 解析模型。
  ///
  /// [payload] 必须至少 52 字节。
  factory RingDeviceInfo.fromPayload(Uint8List payload) {
    if (payload.length < 52) {
      throw const FormatException('Device info payload must be 52 bytes');
    }
    return RingDeviceInfo(
      manufacturer: _ascii(payload, 0, 16),
      model: _ascii(payload, 16, 6),
      firmwareVersion: ringReadUint16(payload, 22),
      hardwareVersion: bytesToHex(payload.sublist(24, 30), separator: ''),
      serialNumber: bytesToHex(payload.sublist(30, 46), separator: ''),
      protocolVersion:
          '${payload[46]}.${payload[47]}.${payload[48]}.${payload[49]}',
      color: payload[50],
      size: payload[51],
    );
  }

  Map<String,dynamic> toJson() {
    return {
      'manufacturer': manufacturer,
      'model': model,
      'firmwareVersion': firmwareVersion,
      'hardwareVersion': hardwareVersion,
      'serialNumber': serialNumber,
      'protocolVersion': protocolVersion,
      'color': color,
      'size': size,
    };
  }
}

/// 电量信息。
class RingBattery {
  /// [percent] 为电量百分比；[chargingState] 为充电状态。
  const RingBattery({required this.percent, required this.chargingState});

  /// 电量百分比，协议范围通常为 1~100。
  final int percent;

  /// 充电状态。
  final RingChargingState chargingState;

  /// 从 2 字节电量 payload 解析模型。
  ///
  /// 第 0 字节为百分比，第 1 字节为充电状态。
  factory RingBattery.fromPayload(Uint8List payload) {
    if (payload.length < 2) {
      throw const FormatException('Battery payload must be 2 bytes');
    }
    return RingBattery(
      percent: payload[0],
      chargingState: payload[1] == 2
          ? RingChargingState.charging
          : RingChargingState.notCharging,
    );
  }
}

/// 充电状态。
enum RingChargingState {
  /// 未充电。
  notCharging,

  /// 充电中。
  charging,
}

/// 实时运动上报。
class RingRealtimeSport {
  /// 创建实时运动数据。
  ///
  /// 当前固件只有 [steps] 是真实有效字段，其余健康/距离字段未实现。
  const RingRealtimeSport({
    required this.startTime,
    required this.sportType,
    required this.nodeTime,
    required this.steps,
  });

  /// 运动开始时间。
  final DateTime startTime;

  /// 运动类型，当前 `0x01` 表示室内健走。
  final int sportType;

  /// 当前节点时间。
  final DateTime nodeTime;

  /// 累计步数。
  final int steps;

  /// 从 29 字节实时运动 payload 解析模型。
  factory RingRealtimeSport.fromPayload(Uint8List payload) {
    if (payload.length < 29) {
      throw const FormatException('Realtime sport payload must be 29 bytes');
    }
    return RingRealtimeSport(
      startTime: _timestamp6(payload, 0),
      sportType: payload[6],
      nodeTime: _timestamp6(payload, 7),
      steps: ringReadUint16(payload, 15),
    );
  }
}

/// 按键计数上报。
class RingButtonCount {
  /// [count] 为戒指当前计数。
  const RingButtonCount(this.count);

  /// 当前计数，协议范围 0~9999。
  final int count;

  /// 从 2 字节按键计数 payload 解析模型。
  factory RingButtonCount.fromPayload(Uint8List payload) {
    if (payload.length < 2) {
      throw const FormatException('Button count payload must be 2 bytes');
    }
    return RingButtonCount(ringReadUint16(payload, 0));
  }
}

/// 一天的赞念小时桶统计。
class RingZikrDay {
  /// 创建赞念日统计。
  ///
  /// [isToday] 区分当天快照和历史天；[hourlyCounts] 固定 24 个小时桶。
  const RingZikrDay({
    required this.isToday,
    required this.date,
    required this.hourlyCounts,
  });

  /// 是否为当天数据；false 表示历史天，业务收到后可调用确认清除。
  final bool isToday;

  /// 数据所属公历日期。
  final DateTime date;

  /// 24 个小时桶，依次对应 0 点到 23 点。
  final List<int> hourlyCounts;

  int get total => hourlyCounts.reduce((a, b) => a + b);

  /// 从 52 字节赞念日 payload 解析模型。
  factory RingZikrDay.fromPayload(Uint8List payload) {
    if (payload.length < 52) {
      throw const FormatException('Zikr day payload must be 52 bytes');
    }
    return RingZikrDay(
      isToday: payload[0] == 1,
      date: DateTime(2000 + payload[1], payload[2], payload[3]),
      hourlyCounts: List.generate(
        24,
        (index) => ringReadUint16(payload, 4 + index * 2),
      ),
    );
  }

  Map<String,dynamic> toJson() {
    return {
      'isToday': isToday,
      'date': date.toIso8601String(),
      'hourlyCounts': hourlyCounts,
      'total': total,
    };
  }
}

/// 设备息屏时间。
class RingScreenOffTime {
  /// [seconds] 为息屏秒数。
  const RingScreenOffTime(this.seconds);

  /// 息屏秒数，只接受 10/20/30/40/50/60。
  final int seconds;
}

String _ascii(Uint8List payload, int offset, int length) {
  final bytes = payload.sublist(offset, offset + length);
  final end = bytes.indexOf(0);
  return String.fromCharCodes(end == -1 ? bytes : bytes.sublist(0, end));
}

DateTime _timestamp6(Uint8List payload, int offset) {
  return DateTime.fromMillisecondsSinceEpoch(
    ringReadUint32(payload, offset) * 1000,
    isUtc: true,
  );
}
