import 'dart:typed_data';

import 'package:common/common.dart';

import '../common/ble_failure.dart';
import '../common/hex_utils.dart';
import '../core/ble_scan_device.dart';
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
    this.screenDirection,
    this.failure,
    this.message,
  });

  /// 正在执行的命令。
  final RingCommand command;

  /// 命令当前阶段。
  final RingActionPhase phase;

  /// 设备返回的原始状态字节，发送中或本地失败时为空。
  final int? status;

  /// 屏幕翻转两段应答携带的当前方向，非屏幕方向相关命令时为空。
  final RingScreenDirection? screenDirection;

  /// 失败详情，仅 [RingActionPhase.failed] 阶段有值。
  final BleFailure? failure;

  /// 调试说明，用于 example 展示状态变化原因。
  final String? message;
}

/// 屏幕方向。
enum RingScreenDirection {
  /// 正常方向。
  normal(0, 'Normal'),

  /// 翻转 180°。
  flipped(1, 'Flipped');

  /// [value] 为协议字节；[label] 为调试展示文案。
  const RingScreenDirection(this.value, this.label);

  /// 协议中的 1 字节方向值。
  final int value;

  /// 调试展示文案。
  final String label;

  /// 从协议字节解析屏幕方向。
  ///
  /// [value] 只能是 0 或 1，否则抛出 [FormatException]。
  static RingScreenDirection fromValue(int value) {
    for (final direction in values) {
      if (direction.value == value) return direction;
    }
    throw FormatException('Invalid screen direction: $value');
  }
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

  Map<String, dynamic> toJson() {
    return {
      'direction': direction,
      'timestamp': timestamp.toIso8601String(),
      'command': command?.toJson(),
      'commandValue': commandValue,
      'hex': hex,
      'description': description,
      'error': error?.toJson(),
    };
  }
}

/// OTA 信息响应。
///
/// 数据来自应用模式命令 `0x0402` 的精确 16 字节 payload。
class RingOtaInfo {
  RingOtaInfo._({
    required this.firmwareVersion,
    required Uint8List productBytes,
    required this.product,
    required this.bootFlags,
    required Uint8List bootVersionBytes,
  }) : _productBytes = Uint8List.fromList(productBytes),
       _bootVersionBytes = Uint8List.fromList(bootVersionBytes);

  /// 应用固件版本，来自 4 字节小端无符号整数。
  final int firmwareVersion;

  final Uint8List _productBytes;

  /// 产品标识的展示文本，仅移除末尾补零，不做大小写或空白归一化。
  final String product;

  /// OTA 能力位原值；高 4 位保留位在解析阶段必须为零。
  final int bootFlags;

  final Uint8List _bootVersionBytes;

  /// 固定 8 字节产品标识副本，供 `.rota` 做包含补零的精确匹配。
  Uint8List get productBytes => Uint8List.fromList(_productBytes);

  /// OTA Bootloader 三段版本号原始字节副本。
  Uint8List get bootVersionBytes => Uint8List.fromList(_bootVersionBytes);

  /// OTA Bootloader 版本展示文本，不参与能力推断。
  String get bootVersion => _bootVersionBytes.join('.');

  /// OTA Bootloader 是否在位。
  bool get bootloaderPresent => bootFlags & 0x01 != 0;

  /// OTA 传输是否要求加密。
  bool get requiresEncryption => bootFlags & 0x02 != 0;

  /// Bootloader 是否校验升级包产品标识。
  bool get validatesProduct => bootFlags & 0x04 != 0;

  /// Bootloader 是否执行最低版本限制。
  bool get enforcesMinimumVersion => bootFlags & 0x08 != 0;

  /// 编码为 `0x0402` 使用的精确 16 字节 payload。
  ///
  /// 返回防御性副本；修改返回值不会影响该对象。
  Uint8List toPayload() {
    final payload = Uint8List(16);
    payload[0] = firmwareVersion & 0xFF;
    payload[1] = (firmwareVersion >> 8) & 0xFF;
    payload[2] = (firmwareVersion >> 16) & 0xFF;
    payload[3] = (firmwareVersion >> 24) & 0xFF;
    payload.setRange(4, 12, _productBytes);
    payload[12] = bootFlags;
    payload.setRange(13, 16, _bootVersionBytes);
    return payload;
  }

  /// 解析 `0x0402` 响应。
  factory RingOtaInfo.fromPayload(Uint8List payload) {
    if (payload.length != 16) {
      throw FormatException(
        'OTA info payload must be exactly 16 bytes, got ${payload.length}',
      );
    }
    final productBytes = Uint8List.fromList(payload.sublist(4, 12));
    final firstPadding = productBytes.indexOf(0);
    final textLength = firstPadding < 0 ? productBytes.length : firstPadding;
    if (firstPadding >= 0 &&
        productBytes.skip(firstPadding).any((value) => value != 0)) {
      throw const FormatException('OTA product contains data after padding');
    }
    if (productBytes
        .take(textLength)
        .any((value) => value < 0x20 || value > 0x7E)) {
      throw const FormatException('OTA product must contain printable ASCII');
    }
    final bootFlags = payload[12];
    if (bootFlags & 0xF0 != 0) {
      throw FormatException(
        'OTA info contains reserved boot flags: 0x${bootFlags.toRadixString(16)}',
      );
    }
    return RingOtaInfo._(
      firmwareVersion: ringReadUint32(payload, 0),
      productBytes: productBytes,
      product: String.fromCharCodes(productBytes.take(textLength)),
      bootFlags: bootFlags,
      bootVersionBytes: Uint8List.fromList(payload.sublist(13, 16)),
    );
  }
}

/// MAC 输入字节序。
enum RingMacByteOrder {
  /// 广播、`0x0101` 和常规文本使用的高位字节在前顺序。
  msbFirst,

  /// PhyPlus 备用 INFO 响应使用的低位字节在前顺序。
  lsbFirst,
}

/// 业务模式戒指与其 OTA 模式设备之间的稳定身份关系。
class RingDeviceIdentity {
  RingDeviceIdentity._(Uint8List applicationMac)
    : _applicationMac = Uint8List.fromList(applicationMac),
      _otaMac = Uint8List.fromList([
        ...applicationMac.take(5),
        (applicationMac[5] + 1) & 0xFF,
      ]);

  final Uint8List _applicationMac;
  final Uint8List _otaMac;

  /// 从规范 MAC 文本创建身份。
  ///
  /// 接受 12 位紧凑十六进制，或统一使用 `:`、`-` 分隔的 6 组两位十六进制。
  factory RingDeviceIdentity.fromMac(String mac) {
    final compact = RegExp(r'^[0-9A-Fa-f]{12}$');
    final separated = RegExp(
      r'^([0-9A-Fa-f]{2})([:\-])([0-9A-Fa-f]{2})(\2[0-9A-Fa-f]{2}){4}$',
    );
    if (!compact.hasMatch(mac) && !separated.hasMatch(mac)) {
      throw FormatException('Invalid ring MAC address: $mac');
    }
    final clean = mac.replaceAll(RegExp('[:-]'), '');
    return RingDeviceIdentity._(
      Uint8List.fromList([
        for (var index = 0; index < 12; index += 2)
          int.parse(clean.substring(index, index + 2), radix: 16),
      ]),
    );
  }

  /// 从 6 字节 MAC 创建身份，并显式声明输入字节序。
  factory RingDeviceIdentity.fromBytes(
    List<int> mac, {
    RingMacByteOrder byteOrder = RingMacByteOrder.msbFirst,
  }) {
    if (mac.length != 6 || mac.any((value) => value < 0 || value > 0xFF)) {
      throw const FormatException('Ring MAC must contain exactly 6 bytes');
    }
    final normalized = switch (byteOrder) {
      RingMacByteOrder.msbFirst => mac,
      RingMacByteOrder.lsbFirst => mac.reversed.toList(),
    };
    return RingDeviceIdentity._(Uint8List.fromList(normalized));
  }

  /// 业务模式 MAC 副本，MSB-first。
  Uint8List get applicationMac => Uint8List.fromList(_applicationMac);

  /// 派生 OTA MAC 副本，MSB-first。
  Uint8List get otaMac => Uint8List.fromList(_otaMac);

  /// 业务模式 MAC 的规范大写文本。
  String get applicationMacText => bytesToHex(_applicationMac, separator: ':');

  /// 派生 OTA MAC 的规范大写文本。
  String get otaMacText => bytesToHex(_otaMac, separator: ':');

  /// 名称或 OTA Service UUID 是否表明这是一个 OTA 候选设备。
  ///
  /// 此结果不能单独用于确认目标身份。
  bool isOtaCandidate(BleScanDevice device) {
    final hasName =
        device.name == RingProtocol.otaDeviceName ||
        device.rawName == RingProtocol.otaDeviceName;
    final otaService = _normalizeUuid(RingProtocol.otaServiceUuid);
    final hasService = device.services.any(
      (service) => _normalizeUuid(service) == otaService,
    );
    return hasName || hasService;
  }

  /// Manufacturer Data 是否携带本身份的派生 OTA MAC。
  bool matchesOtaManufacturerData(BleManufacturerData data) {
    if (data.companyId != RingProtocol.otaManufacturerCompanyId ||
        data.payload.length != 8) {
      return false;
    }
    for (var index = 0; index < _otaMac.length; index++) {
      if (data.payload[index] != _otaMac[index]) return false;
    }
    return true;
  }

  /// 同时通过候选筛选和 Manufacturer Data 身份确认。
  bool matchesOtaDevice(BleScanDevice device) {
    return isOtaCandidate(device) &&
        device.manufacturerData.any(matchesOtaManufacturerData);
  }

  /// 名称、业务 Service 或合法戒指广播是否表明这是业务模式候选设备。
  ///
  /// 候选条件只用于减少扫描结果；仍须由 [matchesApplicationDevice] 用
  /// Manufacturer Data 中的 MAC 确认目标身份。
  bool isApplicationCandidate(BleScanDevice device) {
    final name = device.name ?? device.rawName ?? '';
    final service = _normalizeUuid(RingProtocol.serviceUuid);
    return name.startsWith(RingProtocol.deviceName) ||
        device.services.any((item) => _normalizeUuid(item) == service);
  }

  /// 业务模式 Manufacturer Data 是否携带本身份的原始 MAC。
  bool matchesApplicationManufacturerData(BleManufacturerData data) {
    final advertisement = RingAdvertisement.fromManufacturerData(data);
    final mac = advertisement.valueOrNull?.macAddress;
    if (mac == null || mac.length != _applicationMac.length) return false;
    for (var index = 0; index < mac.length; index++) {
      if (mac[index] != _applicationMac[index]) return false;
    }
    return true;
  }

  /// 同时通过业务候选筛选和 Manufacturer Data 身份确认。
  bool matchesApplicationDevice(BleScanDevice device) {
    return isApplicationCandidate(device) &&
        device.manufacturerData.any(matchesApplicationManufacturerData);
  }

  static String _normalizeUuid(String value) =>
      value.replaceAll('-', '').toLowerCase();
}

/// 智能戒指广播厂商数据。
class RingAdvertisement {
  /// 创建结构化广播厂商数据。
  ///
  /// [companyId] 是底层平台解析出的 Company Identifier；
  /// [identifier] 是协议中的灰鲨标识，当前为 `0x4A59`；
  /// [macAddress] 是广播中的 6 字节设备 MAC，MSB-first；
  /// [firmwareVersion] 是 16-bit 固件版本；[customerId]、[machineId] 当前为占位；
  /// [bindSupported] 是支持绑定原始字段；[bindState] 是绑定状态字节。
  const RingAdvertisement({
    required this.companyId,
    required this.identifier,
    required this.macAddress,
    required this.firmwareVersion,
    required this.customerId,
    required this.machineId,
    required this.bindSupported,
    required this.bindState,
    required this.rawPayload,
  });

  /// 底层平台解析出的 Company Identifier；部分平台可能为协议标识 `0x4A59`。
  final int companyId;

  /// 协议标识，小端字节 `59 4A`，数值为 `0x4A59`。
  final int identifier;

  /// 设备 MAC，6 字节，MSB-first，与屏显/设备信息一致。
  final Uint8List macAddress;

  /// 固件版本，小端 16-bit 整数。
  final int firmwareVersion;

  /// 客户 id，小端 16-bit 整数，当前固件通常为占位 `0x0001`。
  final int customerId;

  /// 机器 id，小端 16-bit 整数，当前固件通常为占位 `0x0001`。
  final int machineId;

  /// 支持绑定原始字段，小端 16-bit 整数。
  final int bindSupported;

  /// 绑定状态原始字节。
  final int bindState;

  /// 原始厂商自定义载荷，便于日志和兼容新版本字段。
  final Uint8List rawPayload;

  /// MAC 十六进制字符串，默认以 `:` 分隔，适合调试 UI 展示。
  String get macAddressText => bytesToHex(macAddress, separator: ':');

  /// 是否已绑定。
  bool get isBound => bindState != 0;

  /// 从扫描结果解析智能戒指厂商数据。
  ///
  /// [device] 为 SDK 扫描结果；若没有符合 `0x4A59` 结构的厂商数据返回失败。
  static Result<RingAdvertisement, BleFailure> fromScanDevice(
    BleScanDevice device,
  ) {
    for (final data in device.manufacturerData) {
      final result = fromManufacturerData(data);
      if (result case Ok<RingAdvertisement, BleFailure>()) {
        return result;
      }
    }
    return const Result.err(
      BleFailure(
        code: BleFailureCode.protocolError,
        message: 'Ring manufacturer data was not found',
      ),
    );
  }

  /// 从单条 BLE 厂商数据解析智能戒指广播字段。
  ///
  /// Android/iOS/Web 对厂商数据的拆分可能不同：有的平台会把前 2 字节作为
  /// [BleManufacturerData.companyId] 并从 [BleManufacturerData.payload] 中移除；
  /// 有的平台会把 `59 4A` 保留在 payload 开头。这里同时兼容两种格式。
  static Result<RingAdvertisement, BleFailure> fromManufacturerData(
    BleManufacturerData data,
  ) {
    final payload = data.payload;
    final Uint8List body;
    final int identifier;
    if (payload.length >= 17 && payload[0] == 0x59 && payload[1] == 0x4A) {
      identifier = ringReadUint16(payload, 0);
      body = payload.sublist(2);
    } else if (data.companyId == RingProtocol.manufacturerIdentifier &&
        payload.length >= 15) {
      identifier = data.companyId;
      body = payload;
    } else {
      return const Result.err(
        BleFailure(
          code: BleFailureCode.protocolError,
          message: 'Manufacturer data is not a ring advertisement',
        ),
      );
    }

    if (body.length < 15) {
      return const Result.err(
        BleFailure(
          code: BleFailureCode.protocolError,
          message: 'Ring manufacturer payload is too short',
        ),
      );
    }

    return Result.ok(
      RingAdvertisement(
        companyId: data.companyId,
        identifier: identifier,
        macAddress: Uint8List.fromList(body.sublist(0, 6)),
        firmwareVersion: ringReadUint16(body, 6),
        customerId: ringReadUint16(body, 8),
        machineId: ringReadUint16(body, 10),
        bindSupported: ringReadUint16(body, 12),
        bindState: body[14],
        rawPayload: Uint8List.fromList(payload),
      ),
    );
  }

  factory RingAdvertisement.fromJson(Map<String, dynamic> json) =>
      RingAdvertisement(
        companyId: json['companyId'] as int,
        identifier: json['identifier'] as int,
        macAddress: Uint8List.fromList(json['macAddress'] as List<int>),
        firmwareVersion: json['firmwareVersion'] as int,
        customerId: json['customerId'] as int,
        machineId: json['machineId'] as int,
        bindSupported: json['bindSupported'] as int,
        bindState: json['bindState'] as int,
        rawPayload: Uint8List.fromList(json['rawPayload'] as List<int>),
      );

  Map<String, dynamic> toJson() => {
    'companyId': companyId,
    'identifier': identifier,
    'macAddress': macAddress.toList(),
    'firmwareVersion': firmwareVersion,
    'customerId': customerId,
    'machineId': machineId,
    'bindSupported': bindSupported,
    'bindState': bindState,
    'rawPayload': rawPayload.toList(),
  };
}

/// 智能戒指扫描结果扩展。
extension RingScanDeviceExtension on BleScanDevice {
  /// 解析当前扫描结果中的智能戒指厂商数据。
  Result<RingAdvertisement, BleFailure> parseRingAdvertisement() {
    return RingAdvertisement.fromScanDevice(this);
  }
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

  Map<String, dynamic> toJson() {
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

/// 自定义赞念模式状态。
///
/// 协议只保存活动标记、当前计数和目标次数，不包含 App 任务 ID 或名称。
class RingCustomZikrState {
  /// 创建自定义赞念状态。
  const RingCustomZikrState({
    required this.active,
    required this.count,
    required this.target,
  });

  /// 是否仍在自定义赞念模式中。
  final bool active;

  /// 当前绝对计数。
  final int count;

  /// 目标次数。
  final int target;

  /// 是否为自动达标后保留的完成状态。
  bool get isCompleted => !active && target > 0 && count == target;

  /// 从 `0x0111 op=2` 的 5 字节响应解析状态。
  factory RingCustomZikrState.fromPayload(Uint8List payload) {
    if (payload.length != 5) {
      throw FormatException(
        'Custom zikr state payload must be exactly 5 bytes, got ${payload.length}',
      );
    }
    final activeValue = payload[0];
    final count = ringReadUint16(payload, 1);
    final target = ringReadUint16(payload, 3);
    if (activeValue > 1) {
      throw FormatException('Custom zikr active must be 0 or 1: $activeValue');
    }
    if (count > 9999 || target > 9999) {
      throw const FormatException(
        'Custom zikr count and target must be <= 9999',
      );
    }
    if (activeValue == 1 && (target == 0 || count >= target)) {
      throw const FormatException(
        'Active custom zikr state must remain below target',
      );
    }
    final isCleared = activeValue == 0 && count == 0 && target == 0;
    final isCompleted = activeValue == 0 && target > 0 && count == target;
    if (activeValue == 0 && !isCleared && !isCompleted) {
      throw const FormatException('Inactive custom zikr state is invalid');
    }
    return RingCustomZikrState(
      active: activeValue == 1,
      count: count,
      target: target,
    );
  }

  /// 编码为 `0x0111 op=2` 的状态 payload。
  Uint8List toPayload() => Uint8List.fromList([
    active ? 1 : 0,
    count & 0xFF,
    (count >> 8) & 0xFF,
    target & 0xFF,
    (target >> 8) & 0xFF,
  ]);

  Map<String, dynamic> toJson() => {
    'active': active,
    'count': count,
    'target': target,
    'completed': isCompleted,
  };
}

/// 自定义赞念设备主动事件。
class RingCustomZikrEvent {
  /// 创建自定义赞念事件。
  const RingCustomZikrEvent({
    required this.event,
    required this.count,
    required this.target,
  });

  /// `0x01` 为进度，`0x02` 为达标。
  final int event;

  /// 当前绝对计数。
  final int count;

  /// 目标次数。
  final int target;

  /// 是否为每次按键后的进度事件。
  bool get isProgress => event == 0x01;

  /// 是否为达标事件。
  bool get isCompleted => event == 0x02;

  /// 从 `0x0307` 的精确 5 字节 payload 解析事件。
  factory RingCustomZikrEvent.fromPayload(Uint8List payload) {
    if (payload.length != 5) {
      throw FormatException(
        'Custom zikr event payload must be exactly 5 bytes, got ${payload.length}',
      );
    }
    final event = payload[0];
    final count = ringReadUint16(payload, 1);
    final target = ringReadUint16(payload, 3);
    if (event != 0x01 && event != 0x02) {
      throw FormatException(
        'Unknown custom zikr event: 0x${event.toRadixString(16)}',
      );
    }
    if (target == 0 || target > 9999 || count > 9999 || count > target) {
      throw const FormatException(
        'Custom zikr event count or target is invalid',
      );
    }
    if (event == 0x01 && count >= target) {
      throw const FormatException(
        'Custom zikr progress event cannot be complete',
      );
    }
    if (event == 0x02 && count != target) {
      throw const FormatException(
        'Custom zikr completion event must reach target',
      );
    }
    return RingCustomZikrEvent(event: event, count: count, target: target);
  }

  Map<String, dynamic> toJson() => {
    'event': event,
    'count': count,
    'target': target,
  };
}

/// 诵经提醒配置项。
class RingPrayerReminder {
  /// 创建一条诵经提醒。
  ///
  /// [enabled] 表示该提醒是否启用；[hour] 为 0~23；
  /// [minute] 为 0~59；[weekdaysMask] 为星期重复位图，bit0=周日，
  /// bit6=周六，`0x7F` 表示每天，`0x00` 表示单次/不重复。
  const RingPrayerReminder({
    required this.enabled,
    required this.start,
    required this.end,
    required this.interval,
  });

  /// 是否启用该提醒。
  final bool enabled;

  /// 小时，协议范围 0~22。
  final int start;

  /// 分钟，协议范围 1-23。
  final int end;

  /// 星期重复位图，bit0=周日，bit6=周六。
  final int interval;

  /// 格式化时间，用于调试 UI 展示。
  String get timeText =>
      '${start.toString().padLeft(2, '0')}:00-${end.toString().padLeft(2, '0')}:00';

  RingPrayerReminder copyWith({
    bool? enabled,
    int? start,
    int? end,
    int? interval,
  }) => RingPrayerReminder(
    enabled: enabled ?? this.enabled,
    start: start ?? this.start,
    end: end ?? this.end,
    interval: interval ?? this.interval,
  );

  /// 校验提醒字段是否符合协议范围。
  Result<void, BleFailure> validate() {
    // if (start < 0 || start > 22 || end < 0 || end > 24) {
    //   return const Result.failure(
    //     BleFailure(
    //       code: BleFailureCode.protocolError,
    //       message: 'Prayer reminder time is out of range',
    //     ),
    //   );
    // }
    // if (weekdaysMask < 0 || weekdaysMask > 0x7F) {
    //   return const Result.failure(
    //     BleFailure(
    //       code: BleFailureCode.protocolError,
    //       message: 'Prayer reminder weekdays mask is out of range',
    //     ),
    //   );
    // }
    return const Result.ok(null);
  }

  /// 编码为协议中的 4 字节提醒项。
  // List<int> toPayloadItem() {
  //   return [enabled ? 1 : 0, hour, minute, weekdaysMask];
  // }

  /// 从协议 4 字节提醒项解析。
  ///
  /// [payload] 是完整提醒表 payload；[offset] 为当前提醒项起始偏移。
  // factory RingPrayerReminder.fromPayloadItem(Uint8List payload, int offset) {
  //   if (offset + 4 > payload.length) {
  //     throw const FormatException('Prayer reminder item is incomplete');
  //   }
  //   if (payload[offset] != 0 && payload[offset] != 1) {
  //     throw const FormatException('Prayer reminder enabled must be 0 or 1');
  //   }
  //   final item = RingPrayerReminder(
  //     enabled: payload[offset] == 1,
  //     hour: payload[offset + 1],
  //     minute: payload[offset + 2],
  //     weekdaysMask: payload[offset + 3],
  //   );
  //   final validation = item.validate();
  //   if (validation case Failure<void>(:final failure)) {
  //     throw FormatException(failure.message);
  //   }
  //   return item;
  // }
  //
  // /// 从完整提醒表 payload 解析提醒列表。
  // ///
  // /// 第 0 字节为条数，后续每条 4 字节，最多 8 条。
  // static List<RingPrayerReminder> listFromPayload(Uint8List payload) {
  //   if (payload.isEmpty) {
  //     throw const FormatException('Prayer reminder payload is empty');
  //   }
  //   final count = payload[0];
  //   if (count > 8) {
  //     throw const FormatException('Prayer reminder count must be <= 8');
  //   }
  //   if (payload.length != 1 + count * 4) {
  //     throw const FormatException('Prayer reminder payload length mismatch');
  //   }
  //   return List.generate(
  //     count,
  //     (index) => RingPrayerReminder.fromPayloadItem(payload, 1 + index * 4),
  //   );
  // }
  //
  // /// 将提醒列表编码为完整提醒表 payload。
  // static Result<Uint8List> listToPayload(List<RingPrayerReminder> reminders) {
  //   if (reminders.length > 8) {
  //     return const Result.failure(
  //       BleFailure(
  //         code: BleFailureCode.protocolError,
  //         message: 'Prayer reminder count must be <= 8',
  //       ),
  //     );
  //   }
  //   final bytes = <int>[reminders.length];
  //   for (final reminder in reminders) {
  //     final validation = reminder.validate();
  //     if (validation case Failure<void>(:final failure)) {
  //       return Result.failure(failure);
  //     }
  //     bytes.addAll(reminder.toPayloadItem());
  //   }
  //   return Result.success(Uint8List.fromList(bytes));
  // }

  Map<String, dynamic> toJson() {
    return {
      'enabled': enabled,
      'start': start,
      'end': end,
      'interval': interval,
    };
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
    if (payload.length != 52) {
      throw FormatException(
        'Zikr day payload must be exactly 52 bytes, got ${payload.length}',
      );
    }
    if (payload[0] != 0 && payload[0] != 1) {
      throw FormatException('Zikr day type must be 0 or 1: ${payload[0]}');
    }
    final year = 2000 + payload[1];
    final month = payload[2];
    final day = payload[3];
    final date = _strictDate(year, month, day);
    return RingZikrDay(
      isToday: payload[0] == 1,
      date: date,
      hourlyCounts: List.generate(
        24,
        (index) => ringReadUint16(payload, 4 + index * 2),
      ),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'isToday': isToday,
      'date': date.toIso8601String(),
      'hourlyCounts': hourlyCounts,
      'total': total,
    };
  }
}

/// `0x0306` 日数据批次结束帧。
class RingZikrBatchEnd {
  /// 创建批次结束信息。
  const RingZikrBatchEnd({
    required this.sentAt,
    required this.previousSentAt,
    required this.dayCount,
  });

  /// 本轮最后一帧入队时的 Unix 秒。
  final int sentAt;

  /// 上一轮发送结束时间的 Unix 秒，首次为 0。
  final int previousSentAt;

  /// 本轮结束帧前发送的日数据帧数。
  final int dayCount;

  /// 从精确 13 字节的 `0x0306` 结束 payload 解析。
  factory RingZikrBatchEnd.fromPayload(Uint8List payload) {
    if (payload.length != 13) {
      throw FormatException(
        'Zikr batch end payload must be exactly 13 bytes, got ${payload.length}',
      );
    }
    if (payload[0] != 0x02 ||
        payload[1] != 0 ||
        payload[2] != 0 ||
        payload[3] != 0) {
      throw const FormatException('Invalid zikr batch end header');
    }
    final dayCount = payload[12];
    if (dayCount > 31) {
      throw FormatException('Zikr batch day count is out of range: $dayCount');
    }
    return RingZikrBatchEnd(
      sentAt: ringReadUint32(payload, 4),
      previousSentAt: ringReadUint32(payload, 8),
      dayCount: dayCount,
    );
  }

  Map<String, dynamic> toJson() => {
    'sentAt': sentAt,
    'previousSentAt': previousSentAt,
    'dayCount': dayCount,
  };
}

/// 设备息屏时间。
class RingScreenOffTime {
  /// [seconds] 为息屏秒数。
  const RingScreenOffTime(this.seconds);

  /// 息屏秒数，只接受 10/20/30/40/50/60。
  final int seconds;

  Map<String, dynamic> toJson() {
    return {'seconds': seconds};
  }
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

DateTime _strictDate(int year, int month, int day) {
  if (month < 1 || month > 12 || day < 1 || day > 31) {
    throw const FormatException('Zikr date is out of range');
  }
  final date = DateTime.utc(year, month, day);
  if (date.year != year || date.month != month || date.day != day) {
    throw const FormatException('Zikr date is invalid');
  }
  return date;
}
