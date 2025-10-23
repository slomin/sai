class Ansi {
  Ansi._();

  static const reset = '\x1B[0m';
  static const green = '\x1B[32m';
  static const blue = '\x1B[34m';
  static const orange = '\x1B[38;5;214m';

  static String wrap(String text, String color) => '$color$text$reset';
}
