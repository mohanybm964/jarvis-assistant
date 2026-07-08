import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_assistant/main.dart';

void main() {
  testWidgets('Jarvis starts successfully', (tester) async {
    await tester.pumpWidget(const JarvisApp());
    await tester.pumpAndSettle();

    expect(
      find.text('JARVIS // PERSONAL INTELLIGENCE'),
      findsOneWidget,
    );

    expect(
      find.text('SYSTEM ONLINE'),
      findsOneWidget,
    );
  });
}
