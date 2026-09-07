import 'dart:async';

import 'package:common/common.dart';

import '../common/ble_failure.dart';
import '../ring/ring_models.dart';
import '../ring/ring_ota_update_session.dart';
import '../ring/ring_protocol.dart';
import '../ring/ring_protocol_adapter.dart';
import 'ble_protocol_adapter.dart';
import 'ble_scan_device.dart';
import 'ble_session.dart';
import 'ble_transport.dart';
import 'universal_ble_transport.dart';

/// BLE SDK 统一门面。
///
/// 业务侧通过该类完成权限、扫描、连接和断开；协议差异由
/// [BleProtocolAdapter] 负责，默认内置智能戒指协议适配器。
class BlueToothSdk {
  /// 创建 SDK 实例。
  ///
  /// [transport] 可注入自定义传输层，测试时常用 fake transport；
  /// [adapters] 为协议适配器列表，默认支持智能戒指。
  BlueToothSdk({
    BleTransport? transport,
    List<BleProtocolAdapter> adapters = const [RingProtocolAdapter()],
  }) : _transport = transport ?? UniversalBleTransport(),
       _adapters = List.of(adapters);

  /// 底层 BLE 传输实现。
  final BleTransport _transport;

  /// 已注册的协议适配器。
  final List<BleProtocolAdapter> _adapters;

  /// 扫描结果流。
  Stream<BleScanDevice> get scanStream => _transport.scanStream;

  /// 蓝牙可用状态变化流。
  Stream<BleAvailability> get availabilityStream =>
      _transport.availabilityStream;

  /// 注册新的协议适配器。
  ///
  /// [adapter] 用于支持新的蓝牙设备或协议。
  void registerAdapter(BleProtocolAdapter adapter) {
    _adapters.add(adapter);
  }

  /// 创建绑定目标戒指身份的跨连接 OTA 更新会话。
  ///
  /// 调用方应先释放现有业务会话；更新会话会自行扫描 OTA/业务模式设备，
  /// 并始终以 Manufacturer Data 中的 MAC 确认目标。
  RingOtaUpdateSession createRingOtaUpdateSession({
    required RingDeviceIdentity identity,
  }) {
    return RingOtaUpdateSession(transport: _transport, identity: identity);
  }

  /// 请求蓝牙运行时权限。
  Future<Result<void, BleFailure>> requestPermissions() {
    return _transport.requestPermissions();
  }

  /// 获取当前蓝牙可用状态。
  Future<Result<BleAvailability, BleFailure>> getAvailability() {
    return _transport.getAvailability();
  }

  /// 开始扫描 BLE 设备。
  ///
  /// [unfiltered] 为 true 时扫描全部设备；为 false 时默认按智能戒指名称
  /// 和 Service UUID 过滤。[serviceIds] 和 [namePrefixes] 可覆盖默认过滤条件。
  Future<Result<void, BleFailure>> startScan({
    bool unfiltered = false,
    List<String> serviceIds = const [RingProtocol.serviceUuid],
    List<String> namePrefixes = const [RingProtocol.deviceName],
  }) {
    return _transport.startScan(
      BleScanOptions(
        serviceIds: serviceIds,
        namePrefixes: namePrefixes,
        unfiltered: unfiltered,
      ),
    );
  }

  /// 停止扫描。
  Future<Result<void, BleFailure>> stopScan() {
    return _transport.stopScan();
  }

  /// 连接扫描到的设备并创建协议会话。
  ///
  /// [device] 为扫描结果；[timeout] 为连接超时；
  /// [autoConnect] 控制是否启用平台自动重连。
  Future<Result<BleSession, BleFailure>> connect(
    BleScanDevice device, {
    Duration timeout = const Duration(seconds: 20),
    bool autoConnect = false,
  }) async {
    await _transport.stopScan();
    final adapter = _adapters.where((item) => item.matches(device)).firstOrNull;
    if (adapter == null) {
      return Result.err(
        BleFailure(
          code: BleFailureCode.unsupported,
          message: 'No BLE protocol adapter matches this device',
        ),
      );
    }

    final connectResult = await _transport.connect(
      device.deviceId,
      timeout: timeout,
      autoConnect: autoConnect,
    );

    if (connectResult case Err(:final error)) {
      return Result.err(error);
    }

    final session = adapter.createSession(
      device: device,
      transport: _transport,
    );
    final initializeResult = await session.initialize();
    if (initializeResult case Err(:final error)) {
      await session.dispose();
      final disconnectResult = await _transport.disconnect(device.deviceId);
      if (disconnectResult case Err(error: final disconnectError)) {
        return Result.err(
          BleFailure(
            code: BleFailureCode.connectionFailed,
            message: 'Session initialization and disconnect cleanup failed',
            cause: (initialization: error, disconnect: disconnectError),
          ),
        );
      }
      return Result.err(error);
    }
    return Result.ok(session);
  }

  /// 按设备 ID 断开连接。
  ///
  /// [deviceId] 为平台设备标识。
  Future<Result<void, BleFailure>> disconnect(String deviceId) {
    return _transport.disconnect(deviceId);
  }

  /// 释放 SDK 底层资源。
  void dispose() {
    _transport.dispose();
  }
}
