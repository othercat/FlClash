import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/core.dart';
import 'package:fl_clash/core/hotspot.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class HotspotGatewayItem extends ConsumerStatefulWidget {
  final CoreController? controller;

  const HotspotGatewayItem({super.key, this.controller});

  @override
  ConsumerState<HotspotGatewayItem> createState() => _HotspotGatewayItemState();
}

class _HotspotGatewayItemState extends ConsumerState<HotspotGatewayItem> {
  HotspotGatewayStatus _status = const HotspotGatewayStatus();
  Timer? _timer;
  bool _busy = false;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    _timer = Timer.periodic(const Duration(seconds: 15), (_) {
      unawaited(_refresh());
    });
  }

  Future<void> _refresh() async {
    if (_busy || _refreshing) {
      return;
    }
    _refreshing = true;
    try {
      final status = await (widget.controller ?? coreController)
          .getHotspotGateway();
      if (mounted && !_busy) {
        setState(() => _status = status);
      }
    } catch (error) {
      if (mounted && !_busy) {
        _reportFailure(error);
      }
    } finally {
      _refreshing = false;
    }
  }

  void _reportFailure(Object error, {bool notify = false}) {
    if (!mounted) {
      return;
    }
    if (notify || _status.error != 'unavailable') {
      commonPrint.log('Hotspot gateway: $error', logLevel: LogLevel.error);
    }
    setState(() {
      _status = HotspotGatewayStatus(
        supported: _status.supported,
        enabled: _status.enabled,
        active: _status.active,
        address: _status.address,
        error: 'unavailable',
      );
    });
    if (notify) {
      context.showNotifier(_message(_status));
    }
  }

  String _message(HotspotGatewayStatus status) {
    final l10n = context.appLocalizations;
    if (status.error.isNotEmpty) {
      return switch (status.error) {
        'tunRequired' => l10n.hotspotGatewayTunRequired,
        'sharingRequired' => l10n.hotspotGatewaySharingRequired,
        'permissionRequired' => l10n.hotspotGatewayPermissionRequired,
        _ => l10n.hotspotGatewayFailed,
      };
    }
    if (status.active) {
      return l10n.hotspotGatewayActive(status.address);
    }
    return l10n.hotspotGatewayDesc;
  }

  Future<void> _setEnabled(bool enabled) async {
    if (_busy) {
      return;
    }
    setState(() => _busy = true);
    ref
        .read(networkSettingProvider.notifier)
        .update((settings) => settings.copyWith(hotspotGateway: enabled));
    try {
      final status = await (widget.controller ?? coreController)
          .setHotspotGateway(enabled);
      if (!mounted) {
        return;
      }
      setState(() => _status = status);
      if (status.error.isNotEmpty) {
        commonPrint.log(
          'Hotspot gateway: ${status.error}',
          logLevel: LogLevel.error,
        );
        context.showNotifier(_message(status));
      }
    } catch (error) {
      _reportFailure(error, notify: true);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: _busy,
      child: ListItem.switchItem(
        title: Text(context.appLocalizations.hotspotGateway),
        subtitle: Text(_message(_status)),
        delegate: SwitchDelegate(
          value: ref.watch(networkSettingProvider).hotspotGateway,
          onChanged: _setEnabled,
        ),
      ),
    );
  }
}
