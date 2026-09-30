import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';
import 'package:grua_testing/grua_testing.dart';

/// The trap that made every sent message disappear.
///
/// `ChatMessage.toJson` drops null fields, so writing a message built in Dart
/// leaves the document with no `sentAt` at all — and Firestore excludes a
/// document that lacks the field a query orders by. The message was saved and
/// never came back on either side. The repositories therefore write the map
/// themselves, with a server timestamp; this pins the reason.
void main() {
  test('a message with no sentAt serialises without the field', () {
    const message = ChatMessage(
      id: 'm-1',
      senderId: 'client-1',
      senderRole: UserRole.client,
      text: 'Hola',
      clientMsgId: 'm-1',
    );

    final json = message.toJson();
    expect(json.containsKey('sentAt'), isFalse);
    expect(json.containsKey('readAt'), isFalse);
    expect(message.isPending, isTrue);
  });

  test('a stamped message keeps its time and is no longer pending', () {
    final sentAt = DateTime.utc(2026, 9, 11, 15, 30);
    final message = ChatMessage(
      id: 'm-2',
      senderId: 'driver-1',
      senderRole: UserRole.driver,
      text: 'Voy en camino',
      clientMsgId: 'm-2',
      sentAt: sentAt,
    );

    expect(message.toJson()['sentAt'], isNotNull);
    expect(message.isPending, isFalse);
    expect(ChatMessage.fromJson(message.toJson()).sentAt, sentAt);
  });

  group('photos in a conversation', () {
    late DemoBackend backend;
    late ChatRepository chat;

    setUp(() {
      backend = DemoBackend()..seed();
      chat = DemoChatRepository(backend);
    });

    tearDown(() => backend.dispose());

    test('an uploaded photo comes back as something the bubble can show',
        () async {
      final upload = await chat.uploadImage(
        serviceId: 'svc-1',
        bytes: Uint8List.fromList(const [1, 2, 3, 4]),
        contentType: 'image/jpeg',
      );

      final url = upload.valueOrNull;
      expect(url, isNotNull);
      // No bucket in demo mode: the photo itself travels in the URL.
      expect(url, startsWith('data:image/jpeg'));
      expect(Uri.parse(url!).data?.contentAsBytes(), [1, 2, 3, 4]);
    });

    test('a photo may travel with no words, but an empty message may not',
        () async {
      final sent = await chat.sendMessage(
        serviceId: 'svc-1',
        senderId: 'demo-client-1',
        senderRole: UserRole.client,
        text: '',
        clientMsgId: 'm-1',
        imageUrl: 'data:image/jpeg;base64,AQIDBA==',
      );
      expect(sent.isOk, isTrue);

      final messages = await backend.messagesFor('svc-1').first;
      expect(messages.single.hasImage, isTrue);
      expect(messages.single.text, isEmpty);

      final empty = await chat.sendMessage(
        serviceId: 'svc-1',
        senderId: 'demo-client-1',
        senderRole: UserRole.client,
        text: '   ',
        clientMsgId: 'm-2',
      );
      expect(empty.failureOrNull?.code, FailureCode.invalidInput);
    });
  });
}
