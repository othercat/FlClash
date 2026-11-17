class HotspotGatewayStatus {
  final bool supported;
  final bool enabled;
  final bool active;
  final String address;
  final String error;

  const HotspotGatewayStatus({
    this.supported = false,
    this.enabled = false,
    this.active = false,
    this.address = '',
    this.error = '',
  });

  factory HotspotGatewayStatus.fromJson(Map<String, dynamic> json) {
    return HotspotGatewayStatus(
      supported: json['supported'] == true,
      enabled: json['enabled'] == true,
      active: json['active'] == true,
      address: json['address'] as String? ?? '',
      error: json['error'] as String? ?? '',
    );
  }
}
