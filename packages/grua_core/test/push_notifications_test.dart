import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';

void main() {
  test('an offer notification says how far and how much', () {
    expect(
      PushNotifications.offerSummary({'distanceM': '3240', 'netCents': '145000'}),
      r'A 3.2 km · Ganas RD$ 1,450',
    );
    expect(PushNotifications.offerSummary({'distanceM': '800'}), 'A 800 m');
    expect(
      PushNotifications.offerSummary(const {}),
      'Tienes una solicitud de grúa',
    );
  });

  test('a notification payload round-trips its data, and junk is ignored', () {
    expect(
      PushNotifications.decodePayload('{"type":"chat","serviceId":"s1"}'),
      {'type': 'chat', 'serviceId': 's1'},
    );
    expect(PushNotifications.decodePayload('not json'), isNull);
    expect(PushNotifications.decodePayload(null), isNull);
  });
}
