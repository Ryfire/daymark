import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:daymark/data/jotlock_send.dart';
import 'package:daymark/providers.dart';
import 'package:daymark/ui/about_screen.dart';

/// Mock for the `daymark/outgoing` platform side: fixed version, records
/// every URL the page asks to open.
class FakeOutgoing {
  final List<String> opened = [];

  late final MethodChannel channel = MethodChannel('test/outgoing/about');

  void install() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'getVersionName':
          return '0.1.0';
        case 'openUrl':
          opened.add(call.arguments['url'] as String);
          return true;
        default:
          return null;
      }
    });
  }
}

Future<(FakeOutgoing, ProviderContainer)> pumpAbout(WidgetTester tester) async {
  final outgoing = FakeOutgoing()..install();
  final container = ProviderContainer(
    overrides: [
      jotlockSenderProvider.overrideWithValue(
        JotlockSender(channel: outgoing.channel),
      ),
    ],
  );
  addTearDown(container.dispose);
  // Taller surface: the About page is a ListView and its lower entries
  // (JotLock link, licenses) are built lazily at the default test size.
  tester.view.physicalSize = const Size(600, 2000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: AboutScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return (outgoing, container);
}

void main() {
  testWidgets('shows the app mark and the version from the channel',
      (tester) async {
    await pumpAbout(tester);

    expect(find.byKey(const Key('about-daymark-mark')), findsOneWidget);
    expect(find.text('Version 0.1.0'), findsOneWidget);
  });

  testWidgets('opens support links through the platform channel',
      (tester) async {
    final (outgoing, _) = await pumpAbout(tester);

    await tester.tap(find.text('Star Daymark on GitHub'));
    await tester.pumpAndSettle();
    expect(
      outgoing.opened,
      contains('https://github.com/Ryfire/daymark'),
    );

    await tester.tap(find.text('Get JotLock'));
    await tester.pumpAndSettle();
    expect(
      outgoing.opened,
      contains('https://github.com/Ryfire/jotlock'),
    );
  });

  testWidgets('offers the open source licenses page', (tester) async {
    await pumpAbout(tester);

    expect(find.text('Open source licenses'), findsOneWidget);
    expect(find.textContaining('Nothing is'), findsOneWidget);
  });
}
