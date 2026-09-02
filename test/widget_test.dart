import 'package:flutter_test/flutter_test.dart';

import 'package:fuelmetrix_flutter_demo/main.dart';

void main() {
  testWidgets('host screen shows the Open mini-app button', (WidgetTester tester) async {
    await tester.pumpWidget(const FuelmetrixHostApp());
    expect(find.text('Open mini-app'), findsOneWidget);
  });
}
