import 'dart:async';
import 'dart:io';

import 'ansi.dart';

class SaiSpinner {
  SaiSpinner({
    required this.sink,
    this.message = 'Sai thinking…',
    this.interval = const Duration(milliseconds: 120),
  });

  final IOSink sink;
  final String message;
  final Duration interval;

  static const List<String> _frames = [
    '⠋',
    '⠙',
    '⠹',
    '⠸',
    '⠼',
    '⠴',
    '⠦',
    '⠧',
    '⠇',
    '⠏',
  ];

  Timer? _timer;
  int _index = 0;
  bool _isRunning = false;

  void start() {
    if (_isRunning) return;
    _isRunning = true;
    _timer = Timer.periodic(interval, (_) {
      final frame = _frames[_index % _frames.length];
      _index++;
      final text = Ansi.wrap('$frame $message', Ansi.orange);
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
