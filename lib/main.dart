import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Icons;
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';

import 'firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  runApp(const SmartFanApp());
}

class SmartFanApp extends StatelessWidget {
  const SmartFanApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const CupertinoApp(
      debugShowCheckedModeBanner: false,
      title: 'AI Smart Fan',
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
  final DatabaseReference _fanRef = FirebaseDatabase.instance.ref('fan');
  final DatabaseReference _rootRef = FirebaseDatabase.instance.ref();

  StreamSubscription<DatabaseEvent>? _fanSub;
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

  double _pricePerKwh = 3000;
  double _actualPowerW = 5;

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

  void _listenFirebase() {
    _fanSub = _fanRef.onValue.listen((event) {
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

      final isOn = _readFanState(data);
      final runtimeSec = _toInt(data['runtimeSec']);
      final powerW = _toDouble(data['powerW']);
      final energyWh = _toDouble(data['energyWh']);
      final energyKWh = _toDouble(data['energyKWh']);

      if (!mounted) return;

      setState(() {
        _isOn = isOn;
        _status = data['status']?.toString() ?? (isOn ? 'ON' : 'OFF');
        _source = data['source']?.toString() ?? '--';
        _lastCommand = data['command']?.toString() ?? 'NONE';
        _lastHex = data['lastHex']?.toString() ?? '--';

        _powerW = powerW > 0 ? powerW : _powerW;
        _actualPowerW = _actualPowerW <= 0 ? _powerW : _actualPowerW;
        _runtimeSec = runtimeSec;
        _energyWh = energyWh;
        _energyKWh = energyKWh;

        _timerActive = _toBool(timer['active']);
        _timerAction = timer['action']?.toString() ?? 'OFF';
        _timerDurationSec = _toInt(timer['durationSec']);
        _timerRemainingSec = _toInt(timer['remainingSec']);

        _loading = false;
      });

      _addChartPoint();

      if (_isOn) {
        if (!_fanController.isAnimating) _fanController.repeat();
      } else {
        _fanController.stop();
      }
    }, onError: (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _showDialog('Lỗi Firebase', 'Không đọc được dữ liệu:\n$e');
    });
  }

  bool _readFanState(Map<dynamic, dynamic> data) {
    if (data.containsKey('isOn')) return _toBool(data['isOn']);
    return data['status']?.toString().toUpperCase() == 'ON';
  }

  bool _toBool(dynamic v) {
    if (v is bool) return v;
    if (v is int) return v == 1;
    if (v is double) return v == 1;
    if (v is String) {
      final text = v.trim().toLowerCase();
      return text == 'true' || text == '1' || text == 'on';
    }
    return false;
  }

  int _toInt(dynamic v) {
    if (v is int) return v;
    if (v is double) return v.round();
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }

  double _toDouble(dynamic v) {
    if (v is double) return v;
    if (v is int) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? 0;
    return 0;
  }

  double get _realEnergyWh => _actualPowerW * _runtimeSec / 3600;
  double get _realEnergyKwh => _realEnergyWh / 1000;
  double get _costVnd => _realEnergyKwh * _pricePerKwh;

  void _addChartPoint() {
    final point = _ChartPoint(
      energyWh: _realEnergyWh,
      runtimeMin: _runtimeSec / 60,
    );

    setState(() {
      _points.add(point);
      if (_points.length > 32) {
        _points.removeAt(0);
      }
    });
  }

  Future<void> _sendCommand(String command) async {
    if (_writing) return;

    setState(() => _writing = true);

    try {
      await _fanRef.child('command').set(command);
    } catch (e) {
      _showDialog('Không gửi được lệnh', 'Lệnh $command bị lỗi:\n$e');
    } finally {
      if (mounted) setState(() => _writing = false);
    }
  }

  Future<void> _startTimer({
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
        'fan/timer/requestedFrom': 'IOS_APP',
        'fan/timer/requestedAt': ServerValue.timestamp,
      });
    } catch (e) {
      _showDialog('Lỗi hẹn giờ', 'Không gửi được hẹn giờ:\n$e');
    } finally {
      if (mounted) setState(() => _writing = false);
    }
  }

  Future<void> _cancelTimer() async {
    setState(() => _writing = true);

    try {
      await _fanRef.child('timer/cancel').set(true);
    } catch (e) {
      _showDialog('Lỗi hủy hẹn giờ', '$e');
    } finally {
      if (mounted) setState(() => _writing = false);
    }
  }

  void _showTimerPicker(String action) {
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
                      action == 'ON' ? 'Hẹn giờ bật' : 'Hẹn giờ tắt',
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
                        _startTimer(minutes: minutes, action: action);
                      },
                    ),
                  ],
                ),
              ),
              Expanded(
                child: CupertinoPicker(
                  itemExtent: 42,
                  scrollController: FixedExtentScrollController(),
                  onSelectedItemChanged: (index) => minutes = index + 1,
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
          title: const Text('Tính điện năng thực tế'),
          message: Column(
            children: [
              const SizedBox(height: 14),
              CupertinoTextField(
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                placeholder: 'Công suất quạt W',
                controller: TextEditingController(text: power.toString()),
                onChanged: (v) => power = double.tryParse(v) ?? power,
              ),
              const SizedBox(height: 12),
              CupertinoTextField(
                keyboardType: TextInputType.number,
                placeholder: 'Giá điện đ/kWh',
                controller: TextEditingController(text: price.toStringAsFixed(0)),
                onChanged: (v) => price = double.tryParse(v) ?? price,
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
    String risk = 'Bình thường';
    final notes = <String>[];

    if (_isOn && !_timerActive && _runtimeSec > 3600) {
      risk = 'Có khả năng quên tắt';
      notes.add('Quạt đã chạy hơn 1 giờ nhưng chưa có hẹn giờ tắt.');
    }

    if (_realEnergyWh > 20) {
      notes.add('Điện năng đang tăng. Nên kiểm tra lại công suất thực tế của quạt.');
    }

    if (_timerActive) {
      notes.add(
        'Đang có hẹn giờ $_timerAction, còn ${_formatDuration(_timerRemainingSec)}.',
      );
    }

    if (notes.isEmpty) {
      notes.add('Hệ thống đang hoạt động ổn định, chưa thấy bất thường.');
    }

    _showDialog(
      'AI Insight',
      'Trạng thái: $risk\n\n'
          'Runtime: ${_formatDuration(_runtimeSec)}\n'
          'Điện năng ước tính: ${_realEnergyWh.toStringAsFixed(4)} Wh\n'
          'Chi phí: ${_costVnd.toStringAsFixed(2)}đ\n\n'
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

  String _formatDuration(int sec) {
    if (sec <= 0) return '00:00';

    final d = Duration(seconds: sec);
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);

    if (h > 0) {
      return '${h.toString().padLeft(2, '0')}:'
          '${m.toString().padLeft(2, '0')}:'
          '${s.toString().padLeft(2, '0')}';
    }

    return '${m.toString().padLeft(2, '0')}:'
        '${s.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _fanSub?.cancel();
    _fanController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      child: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment.topLeft,
            radius: 1.4,
            colors: [
              Color(0xFF0E7490),
              Color(0xFF08111F),
              Color(0xFF050816),
            ],
          ),
        ),
        child: SafeArea(
          child: _loading
              ? const Center(child: CupertinoActivityIndicator(radius: 18))
              : CustomScrollView(
                  slivers: [
                    CupertinoSliverNavigationBar(
                      backgroundColor: const Color(0x66050816),
                      border: null,
                      largeTitle: const Text('AI Fan'),
                      trailing: CupertinoButton(
                        padding: EdgeInsets.zero,
                        onPressed: _showSettings,
                        child: const Icon(CupertinoIcons.slider_horizontal_3),
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
                            _controlCard(),
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
            text: 'Firebase RTDB: /fan',
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
                      'Tiết kiệm điện bắt đầu từ những lần tắt quạt đúng lúc.',
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.5,
                        color: CupertinoColors.white.withOpacity(0.72),
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
                          text: 'Hex: $_lastHex',
                          color: const Color(0xFFF59E0B),
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
        border: Border.all(color: CupertinoColors.white.withOpacity(0.16)),
        boxShadow: [
          BoxShadow(
            color: (_isOn ? const Color(0xFF22D3EE) : CupertinoColors.black)
                .withOpacity(0.35),
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
            size: 70,
            color: _isOn
                ? const Color(0xFFECFEFF)
                : CupertinoColors.white.withOpacity(0.52),
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
                subtitle: 'Theo công suất thực tế',
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
                subtitle: '${_realEnergyKwh.toStringAsFixed(6)} kWh',
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
                    color: CupertinoColors.white.withOpacity(0.58),
                  ),
                ),
              ),
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: color.withOpacity(0.18),
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
              color: CupertinoColors.white.withOpacity(0.55),
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
              border: Border.all(color: CupertinoColors.white.withOpacity(0.08)),
            ),
            child: CustomPaint(
              painter: _EnergyChartPainter(points: _points),
              child: const SizedBox.expand(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _controlCard() {
    return _glassCard(
      padding: const EdgeInsets.all(18),
      child: Column(
        children: [
          _sectionTitle(
            icon: CupertinoIcons.game_controller_solid,
            title: 'Điều khiển nhanh',
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _gradientButton(
                  label: 'Bật quạt',
                  icon: CupertinoIcons.play_fill,
                  colors: const [Color(0xFF16A34A), Color(0xFF22C55E)],
                  onPressed: _writing ? null : () => _sendCommand('ON'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _gradientButton(
                  label: 'Tắt quạt',
                  icon: CupertinoIcons.stop_fill,
                  colors: const [Color(0xFFDC2626), Color(0xFFF97316)],
                  onPressed: _writing ? null : () => _sendCommand('OFF'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _gradientButton(
            label: _isOn ? 'Gạt để tắt quạt' : 'Gạt để bật quạt',
            icon: CupertinoIcons.power,
            colors: _isOn
                ? const [Color(0xFFEF4444), Color(0xFFF97316)]
                : const [Color(0xFF0891B2), Color(0xFF7C3AED)],
            onPressed: _writing
                ? null
                : () => _sendCommand(_isOn ? 'OFF' : 'ON'),
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
                      : 'Chưa có hẹn giờ.\nBạn có thể hẹn bật hoặc tắt từ app.',
                  style: TextStyle(
                    height: 1.55,
                    color: CupertinoColors.white.withOpacity(0.74),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _smallButton(
                  text: 'Hẹn bật',
                  color: const Color(0xFF38BDF8),
                  onPressed:
                      _writing ? null : () => _showTimerPicker('ON'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _smallButton(
                  text: 'Hẹn tắt',
                  color: const Color(0xFFF59E0B),
                  onPressed:
                      _writing ? null : () => _showTimerPicker('OFF'),
                ),
              ),
            ],
          ),
          if (_timerActive) ...[
            const SizedBox(height: 10),
            _smallButton(
              text: 'Hủy hẹn giờ',
              color: const Color(0xFFEF4444),
              onPressed: _writing ? null : _cancelTimer,
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
          _dataRow('Energy ESP32', '${_energyWh.toStringAsFixed(4)} Wh'),
          _dataRow('kWh ESP32', _energyKWh.toStringAsFixed(6)),
          _dataRow('Remote Hex', _lastHex),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _smallButton(
                  text: 'Reset điện năng',
                  color: const Color(0xFFEF4444),
                  onPressed:
                      _writing ? null : () => _sendCommand('RESET_ENERGY'),
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
                color: CupertinoColors.white.withOpacity(0.58),
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
        border: Border.all(color: CupertinoColors.white.withOpacity(0.12)),
        boxShadow: [
          BoxShadow(
            color: CupertinoColors.black.withOpacity(0.28),
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
                color: colors.first.withOpacity(0.28),
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
      color: color.withOpacity(0.92),
      onPressed: onPressed,
      child: Text(
        text,
        style: const TextStyle(
          color: CupertinoColors.white,
          fontWeight: FontWeight.w800,
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
        color: color.withOpacity(0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withOpacity(0.28)),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color.withOpacity(0.95),
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
        color: color.withOpacity(0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withOpacity(0.32)),
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

  _EnergyChartPainter({required this.points});

  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = CupertinoColors.white.withOpacity(0.07)
      ..strokeWidth = 1;

    for (int i = 1; i < 5; i++) {
      final y = size.height * i / 5;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    if (points.length < 2) return;

    final maxEnergy =
        points.map((e) => e.energyWh).reduce(math.max).clamp(0.001, 999999);
    final maxRuntime =
        points.map((e) => e.runtimeMin).reduce(math.max).clamp(0.001, 999999);

    Path energyPath = Path();
    Path runtimePath = Path();

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

  _TimerCirclePainter({required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.width / 2 - 8;

    final bg = Paint()
      ..color = CupertinoColors.white.withOpacity(0.09)
      ..strokeWidth = 10
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final fg = Paint()
      ..shader = const LinearGradient(
        colors: [Color(0xFF22D3EE), Color(0xFFA78BFA)],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height))
      ..strokeWidth = 10
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    canvas.drawCircle(center, radius, bg);

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      progress * math.pi * 2,
      false,
      fg,
    );
  }

  @override
  bool shouldRepaint(covariant _TimerCirclePainter oldDelegate) {
    return oldDelegate.progress != progress;
  }
}
