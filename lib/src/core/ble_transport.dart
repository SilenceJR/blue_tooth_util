import 'dart:async';
import 'dart:typed_data';

import 'package:common/common.dart';

import '../common/ble_failure.dart';
import '../common/result.dart';
import 'ble_scan_device.dart';

/// 蓝牙适配器状态。
enum BleAvailability {
  /// 状态未知。
  unknown,

  /// 蓝牙已开启，可进行扫描和连接。
  poweredOn,

  /// 蓝牙已关闭。
  poweredOff,

  /// 系统未授权当前应用使用蓝牙。
  unauthorized,

  /// 当前平台或设备不支持 BLE。
  unsupported,
}

/// BLE 连接状态。
enum BleLinkState { disconnected, connecting, connected, disconnecting }

/// 扫描配置。
class BleScanOptions {
  /// 创建扫描配置。
  ///
  /// [serviceIds] 按 Service UUID 过滤；[namePrefixes] 按设备名前缀过滤；
  /// [unfiltered] 为 true 时不传过滤条件，用于调试所有设备。
  const BleScanOptions({
    this.serviceIds = const [],
    this.namePrefixes = const [],
    this.unfiltered = false,
  });

  /// 需要匹配的 Service UUID 列表。
  final List<String> serviceIds;

  /// 需要匹配的设备名前缀列表，大小写按平台实现处理。
  final List<String> namePrefixes;

  /// 是否关闭过滤条件，扫描全部附近 BLE 设备。
  final bool unfiltered;
}

/// GATT 服务发现结果。
class BleDiscoveredService {
  /// [uuid] 为服务 UUID；[characteristics] 为该服务下的特征值。
  const BleDiscoveredService({
    required this.uuid,
    required this.characteristics,
  });

  /// GATT Service UUID。
  final String uuid;

  /// 服务下发现的特征值列表。
  final List<BleDiscoveredCharacteristic> characteristics;
}

/// GATT 特征值发现结果。
class BleDiscoveredCharacteristic {
  /// 创建特征值信息。
  ///
  /// [uuid] 为特征 UUID；布尔字段描述该特征支持的读写/通知能力。
  const BleDiscoveredCharacteristic({
    required this.uuid,
    this.canRead = false,
    this.canWrite = false,
    this.canWriteWithoutResponse = false,
    this.canNotify = false,
    this.canIndicate = false,
  });

  /// GATT Characteristic UUID。
  final String uuid;

  /// 是否支持 Read。
  final bool canRead;

  /// 是否支持 Write With Response。
  final bool canWrite;

  /// 是否支持 Write Without Response。
  final bool canWriteWithoutResponse;

  /// 是否支持 Notify。
  final bool canNotify;

  /// 是否支持 Indicate。
  final bool canIndicate;
}

/// BLE 传输层抽象。
///
/// SDK 业务和协议层只依赖该接口，真实实现可使用 `universal_ble`，
/// 测试或模拟器可注入 fake transport。
abstract class BleTransport {
  /// 扫描结果流。
  Stream<BleScanDevice> get scanStream;

  /// 蓝牙可用状态变化流。
  Stream<BleAvailability> get availabilityStream;

  /// 指定设备的连接状态变化流。
  ///
  /// [deviceId] 为平台设备标识。
  Stream<bool> connectionStream(String deviceId);

  /// 指定特征值的 Notify/Indicate 数据流。
  ///
  /// [deviceId] 为设备标识；[characteristicId] 为特征 UUID。
  Stream<Uint8List> valueStream(String deviceId, String characteristicId);

  /// 请求运行时蓝牙权限。
  Future<Result<void,BleFailure>> requestPermissions();

  /// 获取当前蓝牙可用状态。
  Future<Result<BleAvailability,BleFailure>> getAvailability();

  /// 开始扫描。
  ///
  /// [options] 描述扫描过滤条件。
  Future<Result<void,BleFailure>> startScan(BleScanOptions options);

  /// 停止扫描。
  Future<Result<void,BleFailure>> stopScan();

  /// 连接设备。
  ///
  /// [deviceId] 为平台设备标识；[timeout] 为连接超时；
  /// [autoConnect] 是否交给系统自动重连，具体支持情况取决于平台。
  Future<Result<void,BleFailure>> connect(
    String deviceId, {
    Duration timeout = const Duration(seconds: 20),
    bool autoConnect = false,
  });

  /// 断开设备连接。
  ///
  /// [deviceId] 为平台设备标识。
  Future<Result<void,BleFailure>> disconnect(String deviceId);

  /// 请求或查询 MTU。
  ///
  /// [expectedMtu] 为期望 MTU，实际结果由系统和设备协商决定。
  Future<Result<int,BleFailure>> requestMtu(String deviceId, int expectedMtu);

  /// 发现设备 GATT 服务和特征值。
  Future<Result<List<BleDiscoveredService>,BleFailure>> discoverServices(String deviceId);

  /// 订阅特征值通知。
  ///
  /// [serviceId] 为服务 UUID；[characteristicId] 为 Notify 特征 UUID。
  Future<Result<void,BleFailure>> subscribeNotifications(
    String deviceId,
    String serviceId,
    String characteristicId,
  );

  /// 写入特征值。
  ///
  /// [value] 为待写入字节；[withoutResponse] 为 true 时使用无响应写。
  Future<Result<void,BleFailure>> write(
    String deviceId,
    String serviceId,
    String characteristicId,
    Uint8List value, {
    bool withoutResponse = false,
  });

  /// 释放底层资源。
  void dispose();
}
