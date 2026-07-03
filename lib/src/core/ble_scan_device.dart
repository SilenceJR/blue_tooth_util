import 'dart:typed_data';

/// BLE 扫描结果的 SDK 包装模型。
///
/// 业务层通过该模型展示设备、选择设备并传给 [BlueToothSdk.connect]。
class BleScanDevice {
  /// 创建扫描设备信息。
  ///
  /// [deviceId] 是平台返回的设备标识；[name] 是清洗后的名称；
  /// [rawName] 是平台原始名称；[rssi] 是信号强度；
  /// [services]、[manufacturerData]、[serviceData] 来自广播数据。
  const BleScanDevice({
    required this.deviceId,
    this.name,
    this.rawName,
    this.rssi,
    this.paired,
    this.isSystemDevice,
    this.timestamp,
    this.services = const [],
    this.manufacturerData = const [],
    this.serviceData = const {},
  });

  /// 平台设备标识，用于连接、断开和订阅。
  final String deviceId;

  /// 清洗后的设备名称，可能为空。
  final String? name;

  /// 平台返回的原始设备名称，可能包含不可见字符。
  final String? rawName;

  /// 信号强度，单位 dBm；值越接近 0 信号越强。
  final int? rssi;

  /// 平台报告的配对状态，部分平台可能为空。
  final bool? paired;

  /// 是否为系统已连接设备，而不是本次扫描发现的设备。
  final bool? isSystemDevice;

  /// 扫描结果时间戳，单位毫秒；取决于底层平台能力。
  final int? timestamp;

  /// 广播中声明的 Service UUID 列表。
  final List<String> services;

  /// 广播中的厂商数据列表。
  final List<BleManufacturerData> manufacturerData;

  /// 广播中的 Service Data，key 为 Service UUID。
  final Map<String, Uint8List> serviceData;
}

/// BLE 广播厂商数据。
class BleManufacturerData {
  /// [companyId] 为厂商 ID；[payload] 为厂商自定义载荷。
  const BleManufacturerData({required this.companyId, required this.payload});

  /// Bluetooth SIG 分配的 Company Identifier。
  final int companyId;

  /// 厂商自定义广播载荷。
  final Uint8List payload;
}
