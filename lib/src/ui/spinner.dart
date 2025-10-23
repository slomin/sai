import 'dart:async';
import 'dart:io';

class SaiSpinner {
  SaiSpinner({
    required this.sink,
    this.message = 'thinking',
    this.interval = const Duration(milliseconds: 120),
  });

  final IOSink sink;
  final String message;
  final Duration interval;

  static const _frames = ['|', '/', '-', '\\'];

  Timer? _timer;
  int _index = 0;
  bool _isRunning = false;

  void start() {
    if (_isRunning) return;
    _isRunning = true;
    _timer = Timer.periodic(interval, (_) {
      final frame = _frames[_index % _frames.length];
      _index++;
      final text = '$frame $message...';
      sink
        ..write('\r$text')
        ..flush();
    });
  }

  Future<void> stop() async {
    if (!_isRunning) return;
    _isRunning = false;
    _timer?.cancel();
    _timer = null;
    final blank = ' ' * (message.length + 6);
    sink
      ..write('\r$blank\r')
      ..flush();
  }
}
