import 'package:fl_clash/common/theme.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/core/soft_router.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/config/soft_router.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _Handler extends Mock implements CoreHandlerInterface {}

Widget _host(
  CoreController controller, {
  NetworkProps settings = const NetworkProps(
    bypassRouter: false,
    bypassRouterAddress: '10.1.1.8',
  ),
}) {
  return ProviderScope(
    overrides: [networkSettingProvider.overrideWithBuild((_, _) => settings)],
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
      home: Scaffold(body: SoftRouterItem(controller: controller)),
    ),
  );
}

SoftRouterStatus _status({bool enabled = false, String error = ''}) {
  return SoftRouterStatus(
    supported: true,
    enabled: enabled,
    active: enabled,
    address: enabled ? '10.1.1.8' : '',
    selectedAddress: '10.1.1.8',
    ipv6Gateway: enabled ? 'fe80::8' : '',
    ipv6DNS: enabled ? 'fd12:3456::8' : '',
    error: error,
    interfaces: const [SoftRouterInterface(name: 'en0', address: '10.1.1.8')],
  );
}

void main() {
  testWidgets('dual-stack router displays IPs and never restarts the proxy', (
    tester,
  ) async {
    final handler = _Handler();
    when(() => handler.getSoftRouter()).thenAnswer((_) async => _status());
    when(
      () => handler.setSoftRouter(true, '10.1.1.8'),
    ).thenAnswer((_) async => _status(enabled: true));
    await tester.pumpWidget(_host(CoreController.test(handler)));
    await tester.pumpAndSettle();
    expect(find.text('Bypass router mode'), findsOneWidget);
    expect(find.text('Mac LAN IPv4 address'), findsOneWidget);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    final settings = tester.widget<SelectableText>(find.byType(SelectableText));
    expect(settings.data, contains('10.1.1.8'));
    expect(settings.data, contains('fe80::8'));
    expect(settings.data, contains('fd12:3456::8'));
    verify(() => handler.setSoftRouter(true, '10.1.1.8')).called(1);
    verifyNever(() => handler.stopListener());
    verifyNever(() => handler.shutdown(false));
    verifyNever(() => handler.setHotspotGateway(any()));
    clearInteractions(handler);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 4));
    verifyZeroInteractions(handler);
  });

  testWidgets('pending prerequisites never clear the saved router choice', (
    tester,
  ) async {
    final handler = _Handler();
    when(() => handler.getSoftRouter()).thenAnswer((_) async => _status());
    when(
      () => handler.setSoftRouter(true, '10.1.1.8'),
    ).thenAnswer((_) async => _status(error: 'ipv6Required'));
    await tester.pumpWidget(_host(CoreController.test(handler)));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    expect(find.textContaining('Enable IPv6 and DNS IPv6'), findsOneWidget);
    expect(find.byType(SelectableText), findsNothing);
    verifyNever(() => handler.stopListener());
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('router RPC failure is visible and can be retried', (
    tester,
  ) async {
    final handler = _Handler();
    when(() => handler.getSoftRouter()).thenAnswer((_) async => _status());
    when(
      () => handler.setSoftRouter(true, '10.1.1.8'),
    ).thenThrow(StateError('wire decode'));
    when(
      () => handler.setSoftRouter(false, '10.1.1.8'),
    ).thenThrow(StateError('wire decode'));
    await tester.pumpWidget(_host(CoreController.test(handler)));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    expect(
      find.textContaining('Could not update bypass router'),
      findsOneWidget,
    );
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    verify(() => handler.setSoftRouter(true, '10.1.1.8')).called(1);
    verify(() => handler.setSoftRouter(false, '10.1.1.8')).called(1);
    verifyNever(() => handler.stopListener());
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'default-on auto mode shows waiting without changing its choice',
    (tester) async {
      final handler = _Handler();
      when(() => handler.getSoftRouter()).thenAnswer(
        (_) async => const SoftRouterStatus(
          supported: true,
          enabled: true,
          error: 'tunRequired',
        ),
      );
      await tester.pumpWidget(
        _host(CoreController.test(handler), settings: const NetworkProps()),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
      expect(find.textContaining('follow current network'), findsOneWidget);
      expect(find.textContaining('Waiting for the proxy'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('IPv4-only network shows usable IP without empty IPv6 fields', (
    tester,
  ) async {
    final handler = _Handler();
    when(() => handler.getSoftRouter()).thenAnswer(
      (_) async => const SoftRouterStatus(
        supported: true,
        enabled: true,
        active: true,
        address: '192.168.0.221',
      ),
    );
    await tester.pumpWidget(
      _host(CoreController.test(handler), settings: const NetworkProps()),
    );
    await tester.pumpAndSettle();
    final text = tester
        .widget<SelectableText>(find.byType(SelectableText))
        .data;
    expect(text, contains('IPv4 gateway / DNS: 192.168.0.221'));
    expect(text, contains('waiting for usable LAN and TUN IPv6'));
    await tester.pumpWidget(const SizedBox());
  });
}
