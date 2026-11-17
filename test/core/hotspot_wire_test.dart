import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:test/test.dart';

void main() {
  final binary = Platform.environment['FLCLASH_CORE_TEST_BINARY'];
  test(
    'real desktop core accepts generated hotspot JSON on an isolated socket',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      Process? process;
      Socket? socket;
      _Frames? frames;
      Future<String>? diagnostics;
      try {
        // This private instance is never initialized with a profile. It cannot
        // start a listener/TUN or install gateway rules. Never connect to the
        // active application's IPC socket or send it a shutdown action.
        final connection = server.first.timeout(const Duration(seconds: 5));
        process = await Process.start(binary!, ['${server.port}']);
        unawaited(process.stdout.drain<void>());
        diagnostics = process.stderr.transform(utf8.decoder).join();
        socket = await connection;
        frames = _Frames(socket);

        Future<ActionResult> invoke(ActionMethod method, dynamic data) async {
          final action = Action(id: method.name, method: method, data: data);
          final payload = utf8.encode(jsonEncode(action));
          final packet = Uint8List(4 + payload.length);
          ByteData.sublistView(
            packet,
          ).setUint32(0, payload.length, Endian.little);
          packet.setRange(4, packet.length, payload);
          socket!.add(packet);
          await socket.flush();
          final result = await frames!.read().timeout(
            const Duration(seconds: 5),
          );
          expect(result.id, action.id);
          expect(result.method, method);
          expect(result.code, ResultType.success);
          return result;
        }

        final init = await invoke(ActionMethod.getIsInit, null);
        expect(init.data, isFalse);
        final status = await invoke(ActionMethod.getHotspotGateway, null);
        expect(status.data['enabled'], isFalse);
        expect(status.data['active'], isFalse);
        final enable = await invoke(ActionMethod.setHotspotGateway, true);
        expect(enable.data['enabled'], isTrue);
        expect(enable.data['active'], isFalse);
        expect(enable.data['error'], 'tunRequired');
        await invoke(ActionMethod.stopListener, null);
        final paused = await invoke(ActionMethod.getHotspotGateway, null);
        expect(paused.data['enabled'], isTrue);
        expect(paused.data['active'], isFalse);
        await invoke(ActionMethod.startListener, null);
        await invoke(
          ActionMethod.changeProxy,
          jsonEncode(
            const ChangeProxyParams(groupName: 'missing', proxyName: 'missing'),
          ),
        );
        final resumed = await invoke(ActionMethod.getHotspotGateway, null);
        expect(resumed.data['enabled'], isTrue);
        expect(resumed.data['active'], isFalse);
        final disable = await invoke(ActionMethod.setHotspotGateway, false);
        expect(disable.data['enabled'], isFalse);
        expect(disable.data['active'], isFalse);
        final router = await invoke(ActionMethod.getSoftRouter, null);
        expect(router.data['enabled'], isFalse);
        expect(router.data['active'], isFalse);
        final routerEnable = await invoke(ActionMethod.setSoftRouter, {
          'enabled': true,
          'address': '10.1.1.8',
        });
        expect(routerEnable.data['enabled'], isTrue);
        expect(routerEnable.data['active'], isFalse);
        expect(routerEnable.data['error'], 'tunRequired');
        final routerDisable = await invoke(ActionMethod.setSoftRouter, {
          'enabled': false,
          'address': '',
        });
        expect(routerDisable.data['enabled'], isFalse);
        expect(routerDisable.data['active'], isFalse);
      } finally {
        await frames?.cancel();
        await socket?.close();
        await server.close();
        if (process != null) {
          final code = await process.exitCode.timeout(
            const Duration(seconds: 5),
          );
          expect(code, 0, reason: await diagnostics);
        }
      }
    },
    skip: binary == null || !Platform.isMacOS
        ? 'Requires an explicit macOS desktop core binary; no active app IPC is used.'
        : false,
  );
}

class _Frames {
  final StreamIterator<Uint8List> chunks;
  final List<int> buffer = [];

  _Frames(Socket socket) : chunks = StreamIterator(socket);

  Future<ActionResult> read() async {
    Future<void> fill(int count) async {
      while (buffer.length < count) {
        if (!await chunks.moveNext()) {
          throw StateError(
            'Private core connection closed before its response',
          );
        }
        buffer.addAll(chunks.current);
      }
    }

    await fill(4);
    final size = ByteData.sublistView(
      Uint8List.fromList(buffer.take(4).toList()),
    ).getUint32(0, Endian.little);
    if (size > 1024 * 1024) {
      throw StateError('Unexpected private core response size');
    }
    await fill(4 + size);
    final payload = buffer.sublist(4, 4 + size);
    buffer.removeRange(0, 4 + size);
    return ActionResult.fromJson(
      jsonDecode(utf8.decode(payload)) as Map<String, dynamic>,
    );
  }

  Future<void> cancel() => chunks.cancel();
}
