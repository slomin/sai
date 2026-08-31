import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

void main() {
  group('endsWithMarker', () {
    test('the marker alone, or as the final line, counts', () {
      expect(endsWithMarker(proposeMarker), isTrue);
      expect(endsWithMarker('Do less.\n$proposeMarker'), isTrue);
      expect(endsWithMarker('Do less.\n$proposeMarker\n  '), isTrue);
    });

    test('mid-text or mid-line occurrences are ordinary text', () {
      expect(endsWithMarker('use $proposeMarker to ask'), isFalse);
      expect(endsWithMarker('answer $proposeMarker'), isFalse);
      expect(endsWithMarker('$proposeMarker\nmore words'), isFalse);
      expect(endsWithMarker('no marker at all'), isFalse);
    });
  });

  group('shownText', () {
    test('strips the final marker line and the break before it', () {
      expect(shownText('Do less.\n$proposeMarker'), 'Do less.');
      expect(shownText('Do less.\n\n$proposeMarker\n'), 'Do less.');
      expect(shownText(proposeMarker), '');
    });

    test('keeps a mid-text marker as it is', () {
      const text = 'use $proposeMarker tags';
      expect(shownText(text), text);
      expect(shownText(text, streaming: true), text);
    });

    test('holds back a trailing marker prefix only while streaming', () {
      expect(shownText('Ok.\n<sai', streaming: true), 'Ok.');
      expect(shownText('Ok.\n<sai:propose/', streaming: true), 'Ok.');
      expect(shownText('<sai', streaming: true), '');
      expect(shownText('Ok.\n<sai'), 'Ok.\n<sai');
    });

    test('an ordinary last line streams as it is', () {
      expect(shownText('Ok.\nplain', streaming: true), 'Ok.\nplain');
      expect(shownText('Ok.\n', streaming: true), 'Ok.\n');
    });
  });
}
