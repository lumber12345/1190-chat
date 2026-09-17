import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'services/chat_store.dart';
import 'ui/home_screen.dart';
import 'ui/onboarding_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = ChatStore();
  await store.bootstrap();
  runApp(
    ChangeNotifierProvider<ChatStore>.value(
      value: store,
      child: const Chat1190App(),
    ),
  );
}

class Chat1190App extends StatelessWidget {
  const Chat1190App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '1190 Chat',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00897B),
          brightness: Brightness.light,
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00897B),
          brightness: Brightness.dark,
        ),
      ),
      home: const RootGate(),
    );
  }
}

/// Routes between boot / onboarding / main UI.
class RootGate extends StatelessWidget {
  const RootGate({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<ChatStore>();
    switch (store.status) {
      case BootStatus.loading:
        return const Scaffold(
          body: Center(child: CircularProgressIndicator()),
        );
      case BootStatus.needsOnboarding:
        return const OnboardingScreen();
      case BootStatus.ready:
        return const HomeScreen();
    }
  }
}
