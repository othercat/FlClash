import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/common/theme.dart';
import 'package:fl_clash/core/hotspot.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/config/hotspot.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _Handler extends Mock implements CoreHandlerInterface {}

void main() {
  testWidgets('RPC failures are visible and do not leave the switch busy', (
    tester,
  ) async {
    final handler = _Handler();
    final controller = CoreController.test(handler);
    when(
      () => handler.getHotspotGateway(),
    ).thenThrow(StateError('wire decode'));
    when(
      () => handler.setHotspotGateway(true),
    ).thenThrow(StateError('wire encode'));
    when(
      () => handler.setHotspotGateway(false),
    ).thenThrow(StateError('wire encode'));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          networkSettingProvider.overrideWithBuild(
            (_, _) => const NetworkProps(hotspotGateway: false),
          ),
        ],
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.delegate.supportedLocales,
          builder: (context, child) {
            globalState.theme = CommonTheme.of(context, 1);
            return child!;
          },
          home: Scaffold(body: HotspotGatewayItem(controller: controller)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Could not update hotspot sharing'),
      findsOneWidget,
    );
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    verify(() => handler.setHotspotGateway(true)).called(1);
    verify(() => handler.setHotspotGateway(false)).called(1);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    verifyNever(() => handler.stopListener());
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('hotspot switch uses core gateway API and cancels UI polling', (
    tester,
  ) async {
    final handler = _Handler();
    final controller = CoreController.test(handler);
    var enabled = false;
    HotspotGatewayStatus status() => HotspotGatewayStatus(
      supported: true,
      enabled: enabled,
      active: enabled,
      address: enabled ? '192.168.2.1' : '',
    );
    when(() => handler.getHotspotGateway()).thenAnswer((_) async => status());
    when(() => handler.setHotspotGateway(true)).thenAnswer((_) async {
      enabled = true;
      return status();
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          networkSettingProvider.overrideWithBuild(
            (_, _) => const NetworkProps(hotspotGateway: false),
          ),
        ],
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.delegate.supportedLocales,
          builder: (context, child) {
            globalState.theme = CommonTheme.of(context, 1);
            return child!;
          },
          home: Scaffold(body: HotspotGatewayItem(controller: controller)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Enhanced hotspot sharing'), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    expect(find.textContaining('192.168.2.1'), findsOneWidget);
    verify(() => handler.setHotspotGateway(true)).called(1);
    verifyNever(() => handler.stopListener());
    verifyNever(() => handler.shutdown(false));
    clearInteractions(handler);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 4));
    verifyZeroInteractions(handler);
  });
}
