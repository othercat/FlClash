class SoftRouterInterface {
  final String name;
  final String address;

  const SoftRouterInterface({required this.name, required this.address});

  factory SoftRouterInterface.fromJson(Map<String, dynamic> json) {
    return SoftRouterInterface(
      name: json['name'] as String? ?? '',
      address: json['address'] as String? ?? '',
    );
  }
}

class SoftRouterStatus {
  final bool supported;
  final bool enabled;
  final bool active;
  final String address;
  final String selectedAddress;
  final String ipv6Gateway;
  final String ipv6DNS;
  final String error;
  final List<SoftRouterInterface> interfaces;

  const SoftRouterStatus({
    this.supported = false,
    this.enabled = false,
    this.active = false,
    this.address = '',
    this.selectedAddress = '',
    this.ipv6Gateway = '',
    this.ipv6DNS = '',
    this.error = '',
    this.interfaces = const [],
  });

  factory SoftRouterStatus.fromJson(Map<String, dynamic> json) {
    return SoftRouterStatus(
      supported: json['supported'] == true,
      enabled: json['enabled'] == true,
      active: json['active'] == true,
      address: json['address'] as String? ?? '',
      selectedAddress: json['selectedAddress'] as String? ?? '',
      ipv6Gateway: json['ipv6Gateway'] as String? ?? '',
      ipv6DNS: json['ipv6DNS'] as String? ?? '',
      error: json['error'] as String? ?? '',
      interfaces: (json['interfaces'] as List<dynamic>? ?? [])
          .map(
            (item) =>
                SoftRouterInterface.fromJson(item as Map<String, dynamic>),
          )
          .toList(),
    );
  }
}
