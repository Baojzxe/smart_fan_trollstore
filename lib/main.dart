
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart' show Icons;
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'firebase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );

    runApp(const SmartFanApp());
  } catch (e) {
    runApp(
      CupertinoApp(
        debugShowCheckedModeBanner: false,
        home: CupertinoPageScaffold(
          navigationBar: const CupertinoNavigationBar(
            middle: Text('Smart Fan Error'),
          ),
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Center(
                child: Text(
                  'Lỗi khởi tạo Firebase:\n\n$e',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: CupertinoColors.systemRed,
                    fontSize: 15,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
class SmartFanApp extends StatelessWidget {
  const SmartFanApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const CupertinoApp(
      debugShowCheckedModeBanner: false,
      title: 'Smart Fan',
      theme: CupertinoThemeData(
        brightness: Brightness.dark,
        primaryColor: Color(0xFF22D3EE),
        scaffoldBackgroundColor: Color(0xFF050816),
      ),
      home: FanControlScreen(),
    );
  }
}

class FanControlScreen extends StatefulWidget {
  const FanControlScreen({super.key});

  @override
  State<FanControlScreen> createState() => _FanControlScreenState();
}

class _FanControlScreenState extends State<FanControlScreen>
    with SingleTickerProviderStateMixin {
  // ============================================================
  // FIREBASE PATH
  // ============================================================
  final DatabaseReference _rootRef = FirebaseDatabase.instance.ref();
  final DatabaseReference _fanRef = FirebaseDatabase.instance.ref('fan');

  StreamSubscription<DatabaseEvent>? _fanSub;

  // ============================================================
  // BLE CONFIG - ESP32 Nordic UART Service
  // ============================================================
  static const String bleDeviceName = 'SmartFan_BLE';
  static const String bleServiceUuid =
      '6E400001-B5A3-F393-E0A9-E50E24DCCA9E';
  static const String bleRxUuid =
      '6E400002-B5A3-F393-E0A9-E50E24DCCA9E';
  static const String bleTxUuid =
      '6E400003-B5A3-F393-E0A9-E50E24DCCA9E';

  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<List<int>>? _txSub;
  StreamSubscription<BluetoothConnectionState>? _connectionSub;

  final List<ScanResult> _scanResults = [];
  BluetoothDevice? _bleDevice;
  BluetoothCharacteristic? _rxChar;

  bool _bleScanning = false;
  bool _bleConnected = false;
  String _bleStatus = 'Chưa kết nối';
  String _bleLastRx = '--';
  String _bleLastTx = '--';

  // ============================================================
  // UI + DATA
  // ============================================================
  late final AnimationController _fanController;

  bool _loading = true;
  bool _writing = false;

  bool _isOn = false;
  String _status = 'OFF';
  String _source = '--';
  String _lastCommand = 'NONE';
  String _lastHex = '--';

  double _powerW = 5;
  double _energyWh = 0;
  double _energyKWh = 0;
  int _runtimeSec = 0;

  bool _timerActive = false;
  String _timerAction = 'OFF';
  int _timerDurationSec = 0;
  int _timerRemainingSec = 0;

  bool _timerInputActive = false;
  String _timerInputAction = '--';
  String _timerInputDigits = '__';
  int _timerInputCountdown = 0;

  double _actualPowerW = 5;
  double _pricePerKwh = 3000;

  final List<_ChartPoint> _points = [];

  @override
  void initState() {
    super.initState();

    _fanController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 750),
    );

    _listenFirebase();
  }

  // ============================================================
  // FIREBASE
  // ============================================================
  void _listenFirebase() {
    _fanSub = _fanRef.onValue.listen(
      (event) {
        final value = event.snapshot.value;

        if (value == null || value is! Map) {
          if (!mounted) return;
          setState(() => _loading = false);
          return;
        }

        final data = Map<dynamic, dynamic>.from(value);
        final timer = data['timer'] is Map
            ? Map<dynamic, dynamic>.from(data['timer'])
            : <dynamic, dynamic>{};
        final timerInput = data['timerInput'] is Map
            ? Map<dynamic, dynamic>.from(data['timerInput'])
            : <dynamic, dynamic>{};

        final bool isOn = _readFanState(data);
        final int runtimeSec = _toInt(data['runtimeSec']);
        final double powerW = _toDouble(data['powerW']);
        final double energyWh = _toDouble(data['energyWh']);
        final double energyKWh = _toDouble(data['energyKWh']);

        if (!mounted) return;

        setState(() {
          _isOn = isOn;
          _status = data['status']?.toString() ?? (isOn ? 'ON' : 'OFF');
          _source = data['source']?.toString() ?? '--';
          _lastCommand = data['command']?.toString() ?? 'NONE';
          _lastHex = data['lastHex']?.toString() ?? '--';

          _powerW = powerW > 0 ? powerW : _powerW;
          _runtimeSec = runtimeSec;
          _energyWh = energyWh;
          _energyKWh = energyKWh;

          _timerActive = _toBool(timer['active']);
          _timerAction = timer['action']?.toString() ?? 'OFF';
          _timerDurationSec = _toInt(timer['durationSec']);
          _timerRemainingSec = _toInt(timer['remainingSec']);

          _timerInputActive = _toBool(timerInput['active']);
          _timerInputAction =
              timerInput['action']?.toString() ??
              timerInput['type']?.toString() ??
              '--';
          _timerInputDigits =
              timerInput['digits']?.toString().padRight(2, '_') ?? '__';
          if (_timerInputDigits.length > 2) {
            _timerInputDigits = _timerInputDigits.substring(0, 2);
          }
          _timerInputCountdown = _toInt(timerInput['countdownSec']);

          _loading = false;
        });

        _addChartPoint();

        if (_isOn) {
          if (!_fanController.isAnimating) {
            _fanController.repeat();
          }
        } else {
          _fanController.stop();
        }
      },
      onError: (error) {
        if (!mounted) return;
        setState(() => _loading = false);
        _showDialog('Lỗi Firebase', 'Không đọc được /fan:\n$error');
      },
    );
  }

  bool _readFanState(Map<dynamic, dynamic> data) {
    if (data.containsKey('isOn')) return _toBool(data['isOn']);
    return data['status']?.toString().trim().toUpperCase() == 'ON';
  }

  bool _toBool(dynamic value) {
    if (value is bool) return value;
    if (value is int) return value == 1;
    if (value is double) return value == 1;
    if (value is String) {
      final text = value.trim().toLowerCase();
      return text == 'true' || text == '1' || text == 'on';
    }
    return false;
  }

  int _toInt(dynamic value) {
    if (value is int) return value;
    if (value is double) return value.round();
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
  }

  double _toDouble(dynamic value) {
    if (value is double) return value;
    if (value is int) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? 0;
    return 0;
  }

  double get _realEnergyWh => _actualPowerW * _runtimeSec / 3600.0;
  double get _realEnergyKWh => _realEnergyWh / 1000.0;
  double get _costVnd => _realEnergyKWh * _pricePerKwh;

  void _addChartPoint() {
    final point = _ChartPoint(
      energyWh: _realEnergyWh,
      runtimeMin: _runtimeSec / 60.0,
    );

    setState(() {
      _points.add(point);
      if (_points.length > 32) {
        _points.removeAt(0);
      }
    });
  }

  Future<void> _sendFirebaseCommand(String command) async {
    if (_writing) return;

    setState(() => _writing = true);

    try {
      await _fanRef.child('command').set(command);
      _showToast('Đã gửi Firebase: $command');
    } catch (e) {
      _showDialog('Không gửi được Firebase', 'Lệnh $command lỗi:\n$e');
    } finally {
      if (mounted) setState(() => _writing = false);
    }
  }

  Future<void> _startFirebaseTimer({
    required int minutes,
    required String action,
  }) async {
    if (minutes <= 0) return;

    setState(() => _writing = true);

    try {
      await _rootRef.update({
        'fan/timer/action': action,
        'fan/timer/setSeconds': minutes * 60,
        'fan/timer/start': true,
        'fan/timer/cancel': false,
        'fan/timer/requestedFrom': 'IOS_FIREBASE',
        'fan/timer/requestedAt': ServerValue.timestamp,
      });
      _showToast('Đã hẹn $minutes phút -> $action qua Firebase');
    } catch (e) {
      _showDialog('Lỗi hẹn giờ Firebase', '$e');
    } finally {
      if (mounted) setState(() => _writing = false);
    }
  }

  Future<void> _cancelFirebaseTimer() async {
    setState(() => _writing = true);

    try {
      await _fanRef.child('timer/cancel').set(true);
      _showToast('Đã gửi hủy hẹn giờ qua Firebase');
    } catch (e) {
      _showDialog('Lỗi hủy hẹn giờ', '$e');
    } finally {
      if (mounted) setState(() => _writing = false);
    }
  }

  Future<void> _collectDatabase() async {
    if (_writing) return;

    setState(() => _writing = true);

    try {
      final snap = await _fanRef.get();

      if (!snap.exists || snap.value == null || snap.value is! Map) {
        _showDialog('Chưa có dữ liệu', 'Firebase chưa có node /fan.');
        return;
      }

      final raw = Map<dynamic, dynamic>.from(snap.value as Map);
      final data = <String, dynamic>{};

      raw.forEach((key, value) {
        data[key.toString()] = value;
      });

      data['actualPowerW'] = _actualPowerW;
      data['actualEnergyWh'] = _realEnergyWh;
      data['actualEnergyKWh'] = _realEnergyKWh;
      data['actualCostVnd'] = _costVnd;
      data['priceVndPerKWh'] = _pricePerKwh;
      data['collectMode'] = 'IOS_APP';
      data['collectedAtClient'] = DateTime.now().millisecondsSinceEpoch;
      data['collectedAtServer'] = ServerValue.timestamp;

      await _rootRef.child('fan_history').push().set(data);

      _showToast('Đã collect 1 snapshot vào /fan_history');
    } catch (e) {
      _showDialog('Lỗi collect database', '$e');
    } finally {
      if (mounted) setState(() => _writing = false);
    }
  }

  // ============================================================
  // BLE
  // ============================================================
  Future<void> _scanBle() async {
    if (kIsWeb) {
      _showDialog(
        'BLE không chạy trên web',
        'Bluetooth BLE nên test trực tiếp trên iPhone thật.',
      );
      return;
    }

    setState(() {
      _bleScanning = true;
      _bleStatus = 'Đang quét BLE...';
      _scanResults.clear();
    });

    await _scanSub?.cancel();
    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      final filtered = results.where((r) {
        final name = _bleNameOf(r);
        final hasName = name.contains(bleDeviceName);
        final hasService = r.advertisementData.serviceUuids.any(
          (u) => u.toString().toUpperCase() == bleServiceUuid,
        );
        return hasName || hasService;
      }).toList();

      if (!mounted) return;

      setState(() {
        _scanResults
          ..clear()
          ..addAll(filtered);
      });
    });

    try {
      await FlutterBluePlus.stopScan();

      await FlutterBluePlus.startScan(
        withServices: [Guid(bleServiceUuid)],
        timeout: const Duration(seconds: 8),
      );
    } catch (_) {
      try {
        await FlutterBluePlus.startScan(
          withNames: [bleDeviceName],
          timeout: const Duration(seconds: 8),
        );
      } catch (e) {
        _showDialog('Lỗi quét BLE', '$e');
      }
    } finally {
      await Future.delayed(const Duration(seconds: 8));
      if (mounted) {
        setState(() {
          _bleScanning = false;
          _bleStatus = _scanResults.isEmpty
              ? 'Không tìm thấy $bleDeviceName'
              : 'Tìm thấy ${_scanResults.length} thiết bị';
        });
      }
    }
  }

  String _bleNameOf(ScanResult result) {
    final adv = result.advertisementData.advName;
    if (adv.isNotEmpty) return adv;
    final platformName = result.device.platformName;
    if (platformName.isNotEmpty) return platformName;
    final advName = result.device.advName;
    if (advName.isNotEmpty) return advName;
    return result.device.remoteId.toString();
  }

  Future<void> _connectBle(BluetoothDevice device) async {
    setState(() {
      _bleStatus = 'Đang kết nối...';
      _bleDevice = device;
      _rxChar = null;
    });

    try {
      await FlutterBluePlus.stopScan();

      await _connectionSub?.cancel();
      _connectionSub = device.connectionState.listen((state) {
        if (!mounted) return;
        final connected = state == BluetoothConnectionState.connected;
        setState(() {
          _bleConnected = connected;
          _bleStatus = connected ? 'Đã kết nối BLE' : 'Đã ngắt BLE';
        });
      });

      await device.connect(
        license: License.free,
        timeout: const Duration(seconds: 15),
      );

      final services = await device.discoverServices();

      BluetoothCharacteristic? rx;
      BluetoothCharacteristic? tx;

      for (final service in services) {
        if (service.uuid.toString().toUpperCase() == bleServiceUuid) {
          for (final c in service.characteristics) {
            final id = c.uuid.toString().toUpperCase();
            if (id == bleRxUuid) rx = c;
            if (id == bleTxUuid) tx = c;
          }
        }
      }

      if (rx == null || tx == null) {
        throw Exception('Không tìm thấy RX/TX characteristic Nordic UART.');
      }

      _rxChar = rx;

      await _txSub?.cancel();
      _txSub = tx.onValueReceived.listen((value) {
        final text = utf8.decode(value, allowMalformed: true).trim();
        _handleBleNotify(text);
      });

      await tx.setNotifyValue(true);

      if (!mounted) return;

      setState(() {
        _bleConnected = true;
        _bleStatus = 'Đã kết nối $bleDeviceName';
      });

      await _sendBleCommand('STATUS', showOk: false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _bleConnected = false;
        _bleStatus = 'Kết nối lỗi';
      });
      _showDialog('Lỗi kết nối BLE', '$e');
    }
  }

  void _handleBleNotify(String text) {
    if (text.isEmpty) return;

    setState(() {
      _bleLastRx = text;
    });

    if (text.startsWith('STATUS=')) {
      final parts = text.split(';');
      final map = <String, String>{};

      for (final part in parts) {
        final index = part.indexOf('=');
        if (index > 0) {
          map[part.substring(0, index)] = part.substring(index + 1);
        }
      }

      final status = map['STATUS'];
      final runtime = int.tryParse(map['RUNTIME_SEC'] ?? '');
      final energyWh = double.tryParse(map['ENERGY_WH'] ?? '');
      final energyKWh = double.tryParse(map['ENERGY_KWH'] ?? '');

      setState(() {
        if (status != null) {
          _isOn = status.toUpperCase() == 'ON';
          _status = status.toUpperCase();
          _source = 'BLE_STATUS';
        }
        if (runtime != null) _runtimeSec = runtime;
        if (energyWh != null) _energyWh = energyWh;
        if (energyKWh != null) _energyKWh = energyKWh;
      });
    }
  }

  Future<void> _disconnectBle() async {
    try {
      await _txSub?.cancel();
      await _connectionSub?.cancel();
      await _bleDevice?.disconnect();
    } catch (_) {}

    if (!mounted) return;
    setState(() {
      _bleConnected = false;
      _bleStatus = 'Đã ngắt BLE';
      _rxChar = null;
      _bleDevice = null;
    });
  }

  Future<void> _sendBleCommand(
    String command, {
    bool showOk = true,
  }) async {
    final rx = _rxChar;

    if (!_bleConnected || rx == null) {
      _showDialog(
        'Chưa kết nối BLE',
        'Hãy bấm "Quét BLE" rồi kết nối thiết bị $bleDeviceName trước.',
      );
      return;
    }

    try {
      final bytes = utf8.encode(command);
      await rx.write(
        bytes,
        withoutResponse: false,
      );

      setState(() {
        _bleLastTx = command;
      });

      if (showOk) {
        _showToast('Đã gửi BLE: $command');
      }
    } catch (e) {
      _showDialog('Lỗi gửi BLE', '$e');
    }
  }

  Future<void> _sendBleTimer({
    required int minutes,
    required String action,
  }) async {
    final m = minutes.clamp(1, 99).toString().padLeft(2, '0');
    await _sendBleCommand(action == 'ON' ? 'TIMER_ON $m' : 'TIMER_OFF $m');
  }

  // ============================================================
  // SETTINGS + AI
  // ============================================================
  void _showTimerPicker({
    required String action,
    required bool useBle,
  }) {
    int minutes = 1;

    showCupertinoModalPopup(
      context: context,
      builder: (context) {
        return Container(
          height: 330,
          color: const Color(0xFF0F172A),
          child: Column(
            children: [
              Container(
                height: 54,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                decoration: const BoxDecoration(
                  border: Border(
                    bottom: BorderSide(color: Color(0xFF1E293B)),
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    CupertinoButton(
                      padding: EdgeInsets.zero,
                      child: const Text('Hủy'),
                      onPressed: () => Navigator.pop(context),
                    ),
                    Text(
                      '${useBle ? "BLE" : "Firebase"} - ${action == 'ON' ? 'Hẹn bật' : 'Hẹn tắt'}',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        color: CupertinoColors.white,
                      ),
                    ),
                    CupertinoButton(
                      padding: EdgeInsets.zero,
                      child: const Text('Xong'),
                      onPressed: () {
                        Navigator.pop(context);
                        if (useBle) {
                          _sendBleTimer(minutes: minutes, action: action);
                        } else {
                          _startFirebaseTimer(
                            minutes: minutes,
                            action: action,
                          );
                        }
                      },
                    ),
                  ],
                ),
              ),
              Expanded(
                child: CupertinoPicker(
                  itemExtent: 42,
                  scrollController: FixedExtentScrollController(),
                  onSelectedItemChanged: (index) {
                    minutes = index + 1;
                  },
                  children: List.generate(
                    99,
                    (index) => Center(
                      child: Text(
                        '${index + 1} phút',
                        style: const TextStyle(color: CupertinoColors.white),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showSettings() {
    double power = _actualPowerW;
    double price = _pricePerKwh;

    showCupertinoModalPopup(
      context: context,
      builder: (context) {
        return CupertinoActionSheet(
          title: const Text('Cài đặt tính điện năng'),
          message: Column(
            children: [
              const SizedBox(height: 12),
              CupertinoTextField(
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                placeholder: 'Công suất quạt W',
                controller: TextEditingController(
                  text: power.toStringAsFixed(1),
                ),
                onChanged: (value) => power = double.tryParse(value) ?? power,
              ),
              const SizedBox(height: 12),
              CupertinoTextField(
                keyboardType: TextInputType.number,
                placeholder: 'Giá điện đ/kWh',
                controller: TextEditingController(
                  text: price.toStringAsFixed(0),
                ),
                onChanged: (value) => price = double.tryParse(value) ?? price,
              ),
            ],
          ),
          actions: [
            CupertinoActionSheetAction(
              onPressed: () {
                setState(() {
                  _actualPowerW = power <= 0 ? 5 : power;
                  _pricePerKwh = price <= 0 ? 3000 : price;
                });
                Navigator.pop(context);
              },
              child: const Text('Lưu'),
            ),
          ],
          cancelButton: CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(context),
            child: const Text('Đóng'),
          ),
        );
      },
    );
  }

  void _showAiInsight() {
    String level = 'Bình thường';
    final notes = <String>[];

    if (_isOn && !_timerActive && _runtimeSec > 1800) {
      level = 'Nên hẹn giờ tắt';
      notes.add('Quạt đã chạy hơn 30 phút nhưng chưa có hẹn giờ tắt.');
    }

    if (_isOn && !_timerActive && _runtimeSec > 3600) {
      level = 'Có khả năng quên tắt';
      notes.add('Quạt đã chạy hơn 1 giờ. Nên dùng Sleep Timer 15/30/60 phút.');
    }

    if (_realEnergyWh > 20) {
      notes.add('Điện năng đang tăng. Nên kiểm tra lại công suất thực tế.');
    }

    if (_timerActive) {
      notes.add(
        'Đang có hẹn giờ $_timerAction, còn ${_formatDuration(_timerRemainingSec)}.',
      );
    }

    if (_bleConnected) {
      notes.add('BLE đã kết nối, có thể điều khiển cục bộ khi mất Internet.');
    }

    if (notes.isEmpty) {
      notes.add('Hệ thống đang hoạt động ổn định, chưa thấy bất thường.');
    }

    _showDialog(
      'AI Insight',
      'Trạng thái: $level\n\n'
          'Runtime: ${_formatDuration(_runtimeSec)}\n'
          'Điện năng ước tính: ${_realEnergyWh.toStringAsFixed(4)} Wh\n'
          'Chi phí ước tính: ${_costVnd.toStringAsFixed(2)}đ\n\n'
          '${notes.map((e) => '• $e').join('\n')}',
    );
  }

  void _showDialog(String title, String message) {
    if (!mounted) return;

    showCupertinoDialog(
      context: context,
      builder: (context) {
        return CupertinoAlertDialog(
          title: Text(title),
          content: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(message),
          ),
          actions: [
            CupertinoDialogAction(
              child: const Text('Đóng'),
              onPressed: () => Navigator.pop(context),
            ),
          ],
        );
      },
    );
  }

  void _showToast(String message) {
    if (!mounted) return;

    showCupertinoDialog(
      context: context,
      builder: (context) {
        Future.delayed(const Duration(milliseconds: 900), () {
          if (context.mounted) Navigator.of(context).pop();
        });

        return CupertinoAlertDialog(
          content: Text(message),
        );
      },
    );
  }

  String _formatDuration(int seconds) {
    if (seconds <= 0) return '00:00';

    final duration = Duration(seconds: seconds);
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final secs = duration.inSeconds.remainder(60);

    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:'
          '${minutes.toString().padLeft(2, '0')}:'
          '${secs.toString().padLeft(2, '0')}';
    }

    return '${minutes.toString().padLeft(2, '0')}:'
        '${secs.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _fanSub?.cancel();
    _scanSub?.cancel();
    _txSub?.cancel();
    _connectionSub?.cancel();
    _fanController.dispose();
    super.dispose();
  }

  // ============================================================
  // UI
  // ============================================================
  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      child: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment.topLeft,
            radius: 1.35,
            colors: [
              Color(0xFF0E7490),
              Color(0xFF08111F),
              Color(0xFF050816),
            ],
          ),
        ),
        child: SafeArea(
          child: _loading
              ? const Center(
                  child: CupertinoActivityIndicator(radius: 18),
                )
              : CustomScrollView(
                  slivers: [
                    CupertinoSliverNavigationBar(
                      backgroundColor: const Color(0x66050816),
                      border: null,
                      largeTitle: const Text('Smart Fan'),
                      trailing: CupertinoButton(
                        padding: EdgeInsets.zero,
                        onPressed: _showSettings,
                        child: const Icon(
                          CupertinoIcons.slider_horizontal_3,
                        ),
                      ),
                    ),
                    SliverPadding(
                      padding: const EdgeInsets.all(16),
                      sliver: SliverList(
                        delegate: SliverChildListDelegate(
                          [
                            _heroCard(),
                            const SizedBox(height: 16),
                            _metricGrid(),
                            const SizedBox(height: 16),
                            _chartCard(),
                            const SizedBox(height: 16),
                            _firebaseControlCard(),
                            const SizedBox(height: 16),
                            _bleCard(),
                            const SizedBox(height: 16),
                            _timerCard(),
                            const SizedBox(height: 16),
                            _databaseCard(),
                            const SizedBox(height: 30),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _heroCard() {
    return _glassCard(
      padding: const EdgeInsets.all(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _Badge(
            text: 'Firebase + BLE Local',
            icon: CupertinoIcons.cloud_fill,
            color: Color(0xFF22D3EE),
          ),
          const SizedBox(height: 18),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _isOn ? 'ĐANG BẬT' : 'ĐANG TẮT',
                      style: TextStyle(
                        fontSize: 34,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -1.4,
                        color: _isOn
                            ? const Color(0xFF86EFAC)
                            : const Color(0xFFFCA5A5),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Firebase để điều khiển từ xa, BLE để điều khiển cục bộ khi ở gần ESP32.',
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.5,
                        color: CupertinoColors.white.withValues(alpha: 0.72),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _MiniBadge(
                          text: 'Source: $_source',
                          color: const Color(0xFF38BDF8),
                        ),
                        _MiniBadge(
                          text: 'Cmd: $_lastCommand',
                          color: const Color(0xFFA78BFA),
                        ),
                        _MiniBadge(
                          text: 'BLE: ${_bleConnected ? "ON" : "OFF"}',
                          color: _bleConnected
                              ? const Color(0xFF22C55E)
                              : const Color(0xFFF59E0B),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              _fanOrb(),
            ],
          ),
        ],
      ),
    );
  }

  Widget _fanOrb() {
    return Container(
      width: 132,
      height: 132,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: _isOn
              ? const [
                  Color(0xFF86EFAC),
                  Color(0xFF0891B2),
                  Color(0xFF0F172A),
                ]
              : const [
                  Color(0xFF64748B),
                  Color(0xFF1E293B),
                  Color(0xFF020617),
                ],
        ),
        border: Border.all(
          color: CupertinoColors.white.withValues(alpha: 0.16),
        ),
        boxShadow: [
          BoxShadow(
            color: (_isOn ? const Color(0xFF22D3EE) : CupertinoColors.black)
                .withValues(alpha: 0.35),
            blurRadius: 36,
            spreadRadius: 4,
          ),
        ],
      ),
      child: Center(
        child: AnimatedBuilder(
          animation: _fanController,
          builder: (context, child) {
            return Transform.rotate(
              angle: _fanController.value * math.pi * 2,
              child: child,
            );
          },
          child: Icon(
            CupertinoIcons.wind,
            size: 76,
            color: _isOn
                ? const Color(0xFFECFEFF)
                : CupertinoColors.white.withValues(alpha: 0.52),
          ),
        ),
      ),
    );
  }

  Widget _metricGrid() {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _metricCard(
                title: 'Công suất',
                value: '${_actualPowerW.toStringAsFixed(1)} W',
                subtitle: 'Theo cài đặt app',
                icon: CupertinoIcons.bolt_fill,
                color: const Color(0xFFF59E0B),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _metricCard(
                title: 'Runtime',
                value: _formatDuration(_runtimeSec),
                subtitle: '$_runtimeSec giây',
                icon: CupertinoIcons.stopwatch_fill,
                color: const Color(0xFF38BDF8),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _metricCard(
                title: 'Điện năng',
                value: '${_realEnergyWh.toStringAsFixed(4)} Wh',
                subtitle: '${_realEnergyKWh.toStringAsFixed(6)} kWh',
                icon: Icons.electrical_services,
                color: const Color(0xFFA78BFA),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _metricCard(
                title: 'Chi phí',
                value: '${_costVnd.toStringAsFixed(1)}đ',
                subtitle: '${_pricePerKwh.toStringAsFixed(0)}đ/kWh',
                icon: CupertinoIcons.money_dollar_circle_fill,
                color: const Color(0xFF22C55E),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _metricCard({
    required String title,
    required String value,
    required String subtitle,
    required IconData icon,
    required Color color,
  }) {
    return _glassCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title.toUpperCase(),
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.8,
                    color: CupertinoColors.white.withValues(alpha: 0.58),
                  ),
                ),
              ),
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Icon(icon, size: 19, color: color),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            value,
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.8,
              color: CupertinoColors.white,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            subtitle,
            style: TextStyle(
              fontSize: 12,
              color: CupertinoColors.white.withValues(alpha: 0.55),
            ),
          ),
        ],
      ),
    );
  }

  Widget _chartCard() {
    return _glassCard(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle(
            icon: CupertinoIcons.chart_bar_alt_fill,
            title: 'Biểu đồ real-time',
            trailing: '${_points.length} điểm',
          ),
          const SizedBox(height: 16),
          Container(
            height: 190,
            decoration: BoxDecoration(
              color: const Color(0x66020617),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                color: CupertinoColors.white.withValues(alpha: 0.08),
              ),
            ),
            child: CustomPaint(
              painter: _EnergyChartPainter(points: _points),
              child: const SizedBox.expand(),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Đường xanh: Wh · Đường tím: runtime phút',
            style: TextStyle(
              fontSize: 12,
              color: CupertinoColors.white.withValues(alpha: 0.55),
            ),
          ),
        ],
      ),
    );
  }

  Widget _firebaseControlCard() {
    return _glassCard(
      padding: const EdgeInsets.all(18),
      child: Column(
        children: [
          _sectionTitle(
            icon: CupertinoIcons.cloud,
            title: 'Điều khiển từ xa Firebase',
            trailing: '/fan/command',
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _gradientButton(
                  label: 'Bật Quạt',
                  icon: CupertinoIcons.play_fill,
                  colors: const [
                    Color(0xFF16A34A),
                    Color(0xFF22C55E),
                  ],
                  onPressed:
                      _writing ? null : () => _sendFirebaseCommand('ON'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _gradientButton(
                  label: 'Tắt Quạt',
                  icon: CupertinoIcons.stop_fill,
                  colors: const [
                    Color(0xFFDC2626),
                    Color(0xFFF97316),
                  ],
                  onPressed:
                      _writing ? null : () => _sendFirebaseCommand('OFF'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _gradientButton(
            label: 'Reset điện năng Quạt',
            icon: CupertinoIcons.restart,
            colors: const [
              Color(0xFFF59E0B),
              Color(0xFFEF4444),
            ],
            onPressed:
                _writing ? null : () => _sendFirebaseCommand('RESET_ENERGY'),
          ),
        ],
      ),
    );
  }

  Widget _bleCard() {
    return _glassCard(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle(
            icon: CupertinoIcons.bluetooth,
            title: 'Bluetooth BLE cục bộ',
            trailing: _bleConnected ? 'CONNECTED' : 'LOCAL',
          ),
          const SizedBox(height: 12),
          _dataRow('Thiết bị', bleDeviceName),
          _dataRow('Trạng thái', _bleStatus),
          _dataRow('TX gửi', _bleLastTx),
          _dataRow('RX nhận', _bleLastRx),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _smallButton(
                  text: _bleScanning ? 'Đang quét...' : 'Quét BLE',
                  color: const Color(0xFF0891B2),
                  onPressed: _bleScanning ? null : _scanBle,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _smallButton(
                  text: 'Ngắt BLE',
                  color: const Color(0xFF64748B),
                  onPressed: _bleConnected ? _disconnectBle : null,
                ),
              ),
            ],
          ),
          if (_scanResults.isNotEmpty) ...[
            const SizedBox(height: 12),
            ..._scanResults.map((r) {
              final name = _bleNameOf(r);
              return Container(
                margin: const EdgeInsets.only(top: 8),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: CupertinoColors.white.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: CupertinoColors.white.withValues(alpha: 0.10),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(
                      CupertinoIcons.bluetooth,
                      color: Color(0xFF67E8F9),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '$name\nRSSI: ${r.rssi}',
                        style: const TextStyle(
                          color: CupertinoColors.white,
                          height: 1.35,
                        ),
                      ),
                    ),
                    CupertinoButton(
                      padding: EdgeInsets.zero,
                      child: const Text('Kết nối'),
                      onPressed: () => _connectBle(r.device),
                    ),
                  ],
                ),
              );
            }),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _smallButton(
                  text: 'Bật BLE',
                  color: const Color(0xFF22C55E),
                  onPressed:
                      _bleConnected ? () => _sendBleCommand('ON') : null,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _smallButton(
                  text: 'Tắt BLE',
                  color: const Color(0xFFEF4444),
                  onPressed:
                      _bleConnected ? () => _sendBleCommand('OFF') : null,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _smallButton(
                  text: 'Status BLE',
                  color: const Color(0xFF38BDF8),
                  onPressed:
                      _bleConnected ? () => _sendBleCommand('STATUS') : null,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _smallButton(
                  text: 'Reset BLE',
                  color: const Color(0xFFF59E0B),
                  onPressed: _bleConnected
                      ? () => _sendBleCommand('RESET_ENERGY')
                      : null,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _timerCard() {
    final progress = _timerActive && _timerDurationSec > 0
        ? ((_timerDurationSec - _timerRemainingSec) / _timerDurationSec)
            .clamp(0.0, 1.0)
        : 0.0;

    return _glassCard(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle(
            icon: CupertinoIcons.clock_fill,
            title: 'Hẹn giờ',
            trailing: _timerActive ? 'Đang chạy' : 'Đang tắt',
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              SizedBox(
                width: 112,
                height: 112,
                child: CustomPaint(
                  painter: _TimerCirclePainter(progress: progress),
                  child: Center(
                    child: Text(
                      _timerActive
                          ? _formatDuration(_timerRemainingSec)
                          : '--',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                        color: CupertinoColors.white,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  _timerActive
                      ? 'Đang hẹn $_timerAction\nCòn ${_formatDuration(_timerRemainingSec)}'
                      : 'Chưa có hẹn giờ.\nCó thể hẹn qua Firebase hoặc BLE.',
                  style: TextStyle(
                    height: 1.55,
                    color: CupertinoColors.white.withValues(alpha: 0.74),
                  ),
                ),
              ),
            ],
          ),
          if (_timerInputActive) ...[
            const SizedBox(height: 12),
            _MiniBadge(
              text:
                  'Remote nhập $_timerInputAction · $_timerInputDigits · $_timerInputCountdown s',
              color: const Color(0xFFF59E0B),
            ),
          ],
          const SizedBox(height: 16),
          Text(
            'Hẹn giờ Firebase',
            style: TextStyle(
              fontWeight: FontWeight.w800,
              color: CupertinoColors.white.withValues(alpha: 0.86),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _smallButton(
                  text: 'Hẹn bật',
                  color: const Color(0xFF38BDF8),
                  onPressed: _writing
                      ? null
                      : () => _showTimerPicker(
                            action: 'ON',
                            useBle: false,
                          ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _smallButton(
                  text: 'Hẹn tắt',
                  color: const Color(0xFFF59E0B),
                  onPressed: _writing
                      ? null
                      : () => _showTimerPicker(
                            action: 'OFF',
                            useBle: false,
                          ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            'Hẹn giờ BLE',
            style: TextStyle(
              fontWeight: FontWeight.w800,
              color: CupertinoColors.white.withValues(alpha: 0.86),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _smallButton(
                  text: 'BLE bật',
                  color: const Color(0xFF22D3EE),
                  onPressed: _bleConnected
                      ? () => _showTimerPicker(
                            action: 'ON',
                            useBle: true,
                          )
                      : null,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _smallButton(
                  text: 'BLE tắt',
                  color: const Color(0xFFA78BFA),
                  onPressed: _bleConnected
                      ? () => _showTimerPicker(
                            action: 'OFF',
                            useBle: true,
                          )
                      : null,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _smallButton(
                  text: 'Sleep 15m',
                  color: const Color(0xFF22D3EE),
                  onPressed: _writing
                      ? null
                      : () => _startFirebaseTimer(
                            minutes: 15,
                            action: 'OFF',
                          ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _smallButton(
                  text: 'Sleep 30m',
                  color: const Color(0xFFA78BFA),
                  onPressed: _writing
                      ? null
                      : () => _startFirebaseTimer(
                            minutes: 30,
                            action: 'OFF',
                          ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _smallButton(
                  text: 'Sleep 60m',
                  color: const Color(0xFFF59E0B),
                  onPressed: _writing
                      ? null
                      : () => _startFirebaseTimer(
                            minutes: 60,
                            action: 'OFF',
                          ),
                ),
              ),
            ],
          ),
          if (_timerActive) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _smallButton(
                    text: 'Hủy Firebase',
                    color: const Color(0xFFEF4444),
                    onPressed: _writing ? null : _cancelFirebaseTimer,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _smallButton(
                    text: 'Hủy BLE',
                    color: const Color(0xFF64748B),
                    onPressed: _bleConnected
                        ? () => _sendBleCommand('CANCEL_TIMER')
                        : null,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _databaseCard() {
    return _glassCard(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle(
            icon: Icons.storage,
            title: 'Dữ liệu Firebase',
          ),
          const SizedBox(height: 12),
          _dataRow('Status ESP32', _status),
          _dataRow('Source', _source),
          _dataRow('Command', _lastCommand),
          _dataRow('Power ESP32', '${_powerW.toStringAsFixed(1)} W'),
          _dataRow('Energy ESP32', '${_energyWh.toStringAsFixed(4)} Wh'),
          _dataRow('kWh ESP32', _energyKWh.toStringAsFixed(6)),
          _dataRow('Remote Hex', _lastHex),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _smallButton(
                  text: 'Collect DB',
                  color: const Color(0xFF0891B2),
                  onPressed: _writing ? null : _collectDatabase,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _smallButton(
                  text: 'AI Insight',
                  color: const Color(0xFFA78BFA),
                  onPressed: _showAiInsight,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _dataRow(String title, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                color: CupertinoColors.white.withValues(alpha: 0.58),
              ),
            ),
          ),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: const TextStyle(
                color: CupertinoColors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle({
    required IconData icon,
    required String title,
    String? trailing,
  }) {
    return Row(
      children: [
        Icon(icon, color: const Color(0xFF67E8F9), size: 22),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            title,
            style: const TextStyle(
              fontSize: 19,
              fontWeight: FontWeight.w900,
              color: CupertinoColors.white,
              letterSpacing: -0.4,
            ),
          ),
        ),
        if (trailing != null)
          _MiniBadge(text: trailing, color: const Color(0xFF22D3EE)),
      ],
    );
  }

  Widget _glassCard({
    required Widget child,
    EdgeInsets padding = const EdgeInsets.all(16),
  }) {
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: const Color(0xB30F172A),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: CupertinoColors.white.withValues(alpha: 0.12)),
        boxShadow: [
          BoxShadow(
            color: CupertinoColors.black.withValues(alpha: 0.28),
            blurRadius: 32,
            offset: const Offset(0, 16),
          ),
        ],
      ),
      child: child,
    );
  }

  Widget _gradientButton({
    required String label,
    required IconData icon,
    required List<Color> colors,
    required VoidCallback? onPressed,
  }) {
    return GestureDetector(
      onTap: onPressed,
      child: Opacity(
        opacity: onPressed == null ? 0.55 : 1,
        child: Container(
          height: 54,
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: colors),
            borderRadius: BorderRadius.circular(18),
            boxShadow: [
              BoxShadow(
                color: colors.first.withValues(alpha: 0.28),
                blurRadius: 24,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Center(
            child: _writing
                ? const CupertinoActivityIndicator(
                    color: CupertinoColors.white,
                  )
                : Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(icon, color: CupertinoColors.white, size: 20),
                      const SizedBox(width: 9),
                      Text(
                        label,
                        style: const TextStyle(
                          color: CupertinoColors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  Widget _smallButton({
    required String text,
    required Color color,
    required VoidCallback? onPressed,
  }) {
    return CupertinoButton(
      padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 12),
      borderRadius: BorderRadius.circular(16),
      color: color.withValues(alpha: onPressed == null ? 0.35 : 0.92),
      onPressed: onPressed,
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: CupertinoColors.white,
          fontWeight: FontWeight.w800,
          fontSize: 13,
        ),
      ),
    );
  }
}

class _MiniBadge extends StatelessWidget {
  final String text;
  final Color color;

  const _MiniBadge({
    required this.text,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color.withValues(alpha: 0.95),
          fontSize: 12,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final String text;
  final IconData icon;
  final Color color;

  const _Badge({
    required this.text,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.32)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 17),
          const SizedBox(width: 8),
          Text(
            text,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w900,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}

class _ChartPoint {
  final double energyWh;
  final double runtimeMin;

  _ChartPoint({
    required this.energyWh,
    required this.runtimeMin,
  });
}

class _EnergyChartPainter extends CustomPainter {
  final List<_ChartPoint> points;

  _EnergyChartPainter({
    required this.points,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = CupertinoColors.white.withValues(alpha: 0.07)
      ..strokeWidth = 1;

    for (int i = 1; i < 5; i++) {
      final y = size.height * i / 5;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    if (points.length < 2) return;

    final maxEnergy = points
        .map((point) => point.energyWh)
        .reduce(math.max)
        .clamp(0.001, 999999.0);

    final maxRuntime = points
        .map((point) => point.runtimeMin)
        .reduce(math.max)
        .clamp(0.001, 999999.0);

    final energyPath = Path();
    final runtimePath = Path();

    for (int i = 0; i < points.length; i++) {
      final x = size.width * i / (points.length - 1);

      final yEnergy = size.height -
          (points[i].energyWh / maxEnergy * size.height * 0.84) -
          12;

      final yRuntime = size.height -
          (points[i].runtimeMin / maxRuntime * size.height * 0.84) -
          12;

      if (i == 0) {
        energyPath.moveTo(x, yEnergy);
        runtimePath.moveTo(x, yRuntime);
      } else {
        energyPath.lineTo(x, yEnergy);
        runtimePath.lineTo(x, yRuntime);
      }
    }

    final energyPaint = Paint()
      ..color = const Color(0xFF22D3EE)
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final runtimePaint = Paint()
      ..color = const Color(0xFFA78BFA)
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    canvas.drawPath(energyPath, energyPaint);
    canvas.drawPath(runtimePath, runtimePaint);
  }

  @override
  bool shouldRepaint(covariant _EnergyChartPainter oldDelegate) {
    return oldDelegate.points != points;
  }
}

class _TimerCirclePainter extends CustomPainter {
  final double progress;

  _TimerCirclePainter({
    required this.progress,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.width / 2 - 8;

    final bgPaint = Paint()
      ..color = CupertinoColors.white.withValues(alpha: 0.09)
      ..strokeWidth = 10
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final fgPaint = Paint()
      ..shader = const LinearGradient(
        colors: [
          Color(0xFF22D3EE),
          Color(0xFFA78BFA),
        ],
      ).createShader(
        Rect.fromLTWH(0, 0, size.width, size.height),
      )
      ..strokeWidth = 10
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    canvas.drawCircle(center, radius, bgPaint);

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      progress * math.pi * 2,
      false,
      fgPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _TimerCirclePainter oldDelegate) {
    return oldDelegate.progress != progress;
  }
}
