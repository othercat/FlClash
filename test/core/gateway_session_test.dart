import 'dart:async';

import 'package:fl_clash/core/gateway_session.dart';
import 'package:fl_clash/core/hotspot.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/core/soft_router.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

class _Handler extends Mock implements CoreHandlerInterface {}

class _EmptyStatusHandler extends CoreHandlerInterface {
  @override
  Completer<void> get completer => Completer<void>()..complete();

  @override
  Future<T?> invoke<T>({
    required ActionMethod method,
    dynamic data,
    Duration? timeout,
  }) async => null;

  @override
  Future<bool> destroy() async => true;

  @override
  Future<String> preload() async => throw StateError('Status-only fixture');

  @override
  Future<bool> shutdown(bool isUser) async =>
      throw StateError('Status-only fixture');
}

void main() {
  late _Handler handler;
  late GatewaySession session;
  late bool hotspot;
  late bool router;
  late String address;

  setUp(() {
    handler = _Handler();
    session = GatewaySession(handler, supported: true);
    hotspot = router = false;
    address = '';
    when(() => handler.setHotspotGateway(any())).thenAnswer((call) async {
      hotspot = call.positionalArguments[0] as bool;
      return HotspotGatewayStatus(supported: true, enabled: hotspot);
    });
    when(() => handler.setSoftRouter(any(), any())).thenAnswer((call) async {
      router = call.positionalArguments[0] as bool;
      address = call.positionalArguments[1] as String;
      return SoftRouterStatus(
        supported: true,
        enabled: router,
        selectedAddress: address,
      );
    });
    when(() => handler.getHotspotGateway()).thenAnswer(
      (_) async => HotspotGatewayStatus(supported: true, enabled: hotspot),
    );
    when(() => handler.getSoftRouter()).thenAnswer(
      (_) async => SoftRouterStatus(
        supported: true,
        enabled: router,
        selectedAddress: address,
      ),
    );
  });

  test('defaults start both modes only after core/config readiness', () async {
    verifyZeroInteractions(handler);
    await session.ready();
    expect(hotspot, isTrue);
    expect(router, isTrue);
    expect(address, isEmpty);
    clearInteractions(handler);
    await session.getHotspot();
    await session.getRouter();
    verifyNever(() => handler.setHotspotGateway(any()));
    verifyNever(() => handler.setSoftRouter(any(), any()));
    verifyNever(() => handler.stopListener());
    verifyNever(() => handler.shutdown(any()));
  });

  test('saved disable and selected IP survive core reconnection', () async {
    await session.configure(hotspot: false, router: true, address: '10.1.1.8');
    verifyZeroInteractions(handler);
    await session.ready();
    expect(hotspot, isFalse);
    expect(address, '10.1.1.8');
    session.disconnect();
    clearInteractions(handler);
    await session.ready();
    verify(() => handler.setHotspotGateway(false)).called(1);
    verify(() => handler.setSoftRouter(true, '10.1.1.8')).called(1);
    verifyNever(() => handler.setHotspotGateway(true));
  });

  test('later setup immediately rechecks an earlier pending start', () async {
    await session.ready();
    clearInteractions(handler);
    await session.ready();
    verify(() => handler.setHotspotGateway(true)).called(1);
    verify(() => handler.setSoftRouter(true, '')).called(1);
  });

  test('one RPC failure does not disable or block the other mode', () async {
    when(() => handler.setHotspotGateway(true)).thenThrow(StateError('wire'));
    await session.ready();
    expect(router, isTrue);
    when(() => handler.setHotspotGateway(true)).thenAnswer((_) async {
      hotspot = true;
      return const HotspotGatewayStatus(supported: true, enabled: true);
    });
    await session.getHotspot();
    expect(hotspot, isTrue);
    verify(() => handler.setHotspotGateway(true)).called(2);
    verifyNever(() => handler.setHotspotGateway(false));
  });

  test('disconnect invalidates a delayed old-core restore', () async {
    final response = Completer<HotspotGatewayStatus>();
    when(
      () => handler.setHotspotGateway(true),
    ).thenAnswer((_) => response.future);
    final pending = session.ready();
    await Future<void>.delayed(Duration.zero);
    session.disconnect();
    final configure = session.configure(
      hotspot: false,
      router: false,
      address: '',
    );
    response.complete(
      const HotspotGatewayStatus(supported: true, enabled: true),
    );
    await pending;
    await configure;
    verifyNever(() => handler.setSoftRouter(true, ''));
    await session.ready();
    expect(hotspot, isFalse);
    expect(router, isFalse);
  });

  test('manual disable queued during restore is the final state', () async {
    final response = Completer<HotspotGatewayStatus>();
    when(
      () => handler.setHotspotGateway(true),
    ).thenAnswer((_) => response.future);
    final pending = session.ready();
    await Future<void>.delayed(Duration.zero);
    final disabled = session.setHotspot(false);
    response.complete(
      const HotspotGatewayStatus(supported: true, enabled: true),
    );
    await pending;
    await disabled;
    await session.ready();
    expect(hotspot, isFalse);
    verify(() => handler.setHotspotGateway(true)).called(1);
  });

  test('non-Mac readiness never applies gateway rules', () async {
    final unsupported = GatewaySession(handler, supported: false);
    await unsupported.ready();
    await unsupported.configure(hotspot: true, router: true, address: '');
    verifyZeroInteractions(handler);
  });

  test(
    'missing status responses are errors, never manufactured off states',
    () async {
      final empty = _EmptyStatusHandler();
      await expectLater(empty.getHotspotGateway(), throwsStateError);
      await expectLater(empty.getSoftRouter(), throwsStateError);
    },
  );
}
