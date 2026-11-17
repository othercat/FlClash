import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/core.dart';
import 'package:fl_clash/core/soft_router.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class SoftRouterItem extends ConsumerStatefulWidget {
  final CoreController? controller;

  const SoftRouterItem({super.key, this.controller});

  @override
  ConsumerState<SoftRouterItem> createState() => _SoftRouterItemState();
}

class _SoftRouterItemState extends ConsumerState<SoftRouterItem> {
  SoftRouterStatus _status = const SoftRouterStatus();
  String _address = '';
  String _failure = '';
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

  void _accept(SoftRouterStatus status) {
    _status = status;
    _failure = '';
    _address = ref.read(networkSettingProvider).bypassRouterAddress;
  }

  void _reportFailure(Object error, {bool notify = false}) {
    if (!mounted) return;
    if (notify || _failure.isEmpty) {
      commonPrint.log('Soft router: $error', logLevel: LogLevel.error);
    }
    setState(() => _failure = 'unavailable');
    if (notify) context.showNotifier(_message());
  }

  Future<void> _refresh() async {
    if (_busy || _refreshing) return;
    _refreshing = true;
    try {
      final status = await (widget.controller ?? coreController)
          .getSoftRouter();
      if (mounted && !_busy) setState(() => _accept(status));
    } catch (error) {
      if (mounted && !_busy) _reportFailure(error);
    } finally {
      _refreshing = false;
    }
  }

  String _message() {
    final l10n = context.appLocalizations;
    final error = _failure.isNotEmpty ? _failure : _status.error;
    if (error.isNotEmpty) {
      if (error.startsWith('dns:')) return l10n.softRouterDNSFailed;
      return switch (error) {
        'tunRequired' => l10n.softRouterTunRequired,
        'ipv6Required' => l10n.softRouterIPv6Required,
        'lanRequired' => l10n.softRouterLANRequired,
        'lanIPv6Required' => l10n.softRouterLANIPv6Required,
        'permissionRequired' => l10n.hotspotGatewayPermissionRequired,
        'disableBeforeChanging' => l10n.softRouterDisableBeforeChanging,
        _ => l10n.softRouterFailed,
      };
    }
    return l10n.softRouterDesc;
  }

  Future<void> _setEnabled(bool enabled) async {
    if (_busy) return;
    setState(() => _busy = true);
    ref
        .read(networkSettingProvider.notifier)
        .update(
          (settings) => settings.copyWith(
            bypassRouter: enabled,
            bypassRouterAddress: _address,
          ),
        );
    try {
      final status = await (widget.controller ?? coreController).setSoftRouter(
        enabled,
        _address,
      );
      if (!mounted) return;
      setState(() => _accept(status));
      if (status.error.isNotEmpty) {
        commonPrint.log(
          'Soft router: ${status.error}',
          logLevel: LogLevel.error,
        );
        context.showNotifier(_message());
      }
    } catch (error) {
      _reportFailure(error, notify: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.appLocalizations;
    final settings = ref.watch(networkSettingProvider);
    final addresses = [
      '',
      ..._status.interfaces.map((item) => item.address),
      if (settings.bypassRouterAddress.isNotEmpty &&
          !_status.interfaces.any(
            (item) => item.address == settings.bypassRouterAddress,
          ))
        settings.bypassRouterAddress,
    ];
    return IgnorePointer(
      ignoring: _busy,
      child: Column(
        children: [
          ListItem.switchItem(
            title: Text(l10n.softRouter),
            subtitle: Text(_message()),
            delegate: SwitchDelegate(
              value: settings.bypassRouter,
              onChanged: _setEnabled,
            ),
          ),
          if (addresses.isNotEmpty)
            IgnorePointer(
              ignoring: settings.bypassRouter,
              child: ListItem.options(
                title: Text(l10n.softRouterLANAddress),
                subtitle: Text(
                  _address.isEmpty ? l10n.bypassRouterAutoAddress : _address,
                ),
                delegate: OptionsDelegate<String>(
                  title: l10n.softRouterLANAddress,
                  options: addresses,
                  value: _address,
                  textBuilder: (address) {
                    if (address.isEmpty) return l10n.bypassRouterAutoAddress;
                    final item = _status.interfaces
                        .where((item) => item.address == address)
                        .firstOrNull;
                    return item == null ? address : '$address · ${item.name}';
                  },
                  onChanged: (address) {
                    if (address != null) {
                      setState(() => _address = address);
                      ref
                          .read(networkSettingProvider.notifier)
                          .update(
                            (value) =>
                                value.copyWith(bypassRouterAddress: address),
                          );
                    }
                  },
                ),
              ),
            ),
          if (_status.active)
            ListItem(
              title: Text(l10n.softRouterClientSettings),
              subtitle: SelectableText(
                _status.ipv6DNS.isEmpty
                    ? l10n.bypassRouterIPv4Active(_status.address)
                    : l10n.softRouterActive(
                        _status.address,
                        _status.ipv6Gateway,
                        _status.ipv6DNS,
                      ),
              ),
            ),
        ],
      ),
    );
  }
}
