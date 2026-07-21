import 'dart:async';

import 'package:common/common.dart';

import '../common/ble_failure.dart';

/// 已连接设备会话的基础接口。
abstract class BleSession {
  /// 平台设备标识。
  String get deviceId;

  /// 连接状态变化流，true 表示已连接，false 表示已断开。
  Stream<bool> get connectionStream;

  /// 初始化会话。
  ///
  /// 通常在这里完成 MTU 协商、服务发现和 Notify 订阅。
  Future<Result<void,BleFailure>> initialize();

  /// 主动断开设备。
  Future<Result<void,BleFailure>> disconnect();

  /// 释放会话中的订阅、队列和流控制器。
  Future<void> dispose();
}
