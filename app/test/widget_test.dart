import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:chat1190/models/models.dart';
import 'package:chat1190/services/chat_store.dart';
import 'package:chat1190/main.dart';
import 'package:chat1190/ui/widgets.dart';

void main() {
  testWidgets('RootGate shows onboarding for a fresh identity', (tester) async {
    final store = ChatStore(autoStartTransports: false)
      ..status = BootStatus.needsOnboarding;
    await tester.pumpWidget(
      ChangeNotifierProvider<ChatStore>.value(
        value: store,
        child: const Chat1190App(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Welcome to 1190 Chat'), findsOneWidget);
    expect(find.byType(TextField), findsWidgets);
    store.dispose();
  });

  testWidgets('PeerAvatar renders initials', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: PeerAvatar(name: 'Ada Lovelace', presence: Presence.online),
        ),
      ),
    );
    expect(find.text('AL'), findsOneWidget);
  });

  testWidgets('MessageBubble renders text and read ticks', (tester) async {
    final m = Message(
      id: '1',
      conversationId: 'c',
      senderId: 'me',
      kind: MessageKind.text,
      text: 'Hello world',
      createdAt: DateTime.now().millisecondsSinceEpoch,
      state: DeliveryState.read,
      outgoing: true,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: m,
            senderName: 'You',
            showSender: false,
            progress: null,
          ),
        ),
      ),
    );
    expect(find.text('Hello world'), findsOneWidget);
    // read state -> done_all icon
    expect(find.byIcon(Icons.done_all), findsOneWidget);
  });

  testWidgets('Attachment bubble shows a progress indicator while transferring',
      (tester) async {
    final m = Message(
      id: '2',
      conversationId: 'c',
      senderId: 'me',
      kind: MessageKind.file,
      fileName: 'big.zip',
      fileSize: 10 * 1024 * 1024,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      state: DeliveryState.sending,
      outgoing: true,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: m,
            senderName: 'You',
            showSender: false,
            progress: 0.4,
          ),
        ),
      ),
    );
    expect(find.text('big.zip'), findsOneWidget);
    expect(find.text('10 MB'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });
}
