import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';

void main() async {
  // Đảm bảo các dịch vụ hệ thống được khởi tạo trước khi chạy Firebase
  WidgetsFlutterBinding.ensureInitialized();
  
  // Khởi tạo Firebase
  await Firebase.initializeApp();
  
  runApp(const SmartFanApp());
}

class SmartFanApp extends StatelessWidget {
  const SmartFanApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false, // Tắt nhãn Debug cho đẹp
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const FanControlScreen(),
    );
  }
}

class FanControlScreen extends StatefulWidget {
  const FanControlScreen({super.key});

  @override
  State<FanControlScreen> createState() => _FanControlScreenState();
}

class _FanControlScreenState extends State<FanControlScreen> {
  // Tạo tham chiếu đến Realtime Database
  final DatabaseReference _fanRef = FirebaseDatabase.instance.ref("fan_status");
  bool _isFanOn = false;

  @override
  void initState() {
    super.initState();
    // Lắng nghe sự thay đổi trạng thái từ Firebase (Realtime)
    _fanRef.onValue.listen((event) {
      final data = event.snapshot.value;
      if (data != null) {
        setState(() {
          _isFanOn = data as bool;
        });
      }
    });
  }

  void _toggleFan() {
    // Đảo ngược trạng thái và gửi lên Firebase
    _fanRef.set(!_isFanOn);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[100],
      appBar: AppBar(title: const Text("TrollStore Smart Fan")),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Hiệu ứng cánh quạt (nếu bật thì màu xanh, tắt màu xám)
            AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              padding: const EdgeInsets.all(40),
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: _isFanOn ? Colors.blue.withOpacity(0.3) : Colors.black12,
                    blurRadius: 20,
                    spreadRadius: 5,
                  )
                ],
              ),
              child: Icon(
                Icons.toys,
                size: 100,
                color: _isFanOn ? Colors.blue : Colors.grey,
              ),
            ),
            const SizedBox(height: 50),
            Text(
              _isFanOn ? "QUẠT ĐANG BẬT" : "QUẠT ĐANG TẮT",
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 30),
            ElevatedButton(
              onPressed: _toggleFan,
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 50, vertical: 15),
                backgroundColor: _isFanOn ? Colors.redAccent : Colors.green,
              ),
              child: Text(
                _isFanOn ? "DỪNG QUẠT" : "KHỞI ĐỘNG",
                style: const TextStyle(color: Colors.white, fontSize: 18),
              ),
            ),
          ],
        ),
      ),
    );
  }
}