import 'package:flutter/material.dart';
import 'app_shell.dart';
import 'local_store.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const RydahApp());
}

const ink = Color(0xFF0A1424), teal = Color(0xFF63E3C4);

class RydahApp extends StatelessWidget {
  const RydahApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Rydah',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: ink,
      colorScheme: ColorScheme.fromSeed(
        seedColor: teal,
        brightness: Brightness.dark,
      ),
      useMaterial3: true,
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
        filled: true,
      ),
    ),
    home: const StoreLoader(),
  );
}

class StoreLoader extends StatefulWidget {
  const StoreLoader({super.key});
  @override
  State<StoreLoader> createState() => _StoreLoaderState();
}

class _StoreLoaderState extends State<StoreLoader> {
  late Future<LocalStore> loading = LocalStore.open();
  @override
  Widget build(BuildContext context) => FutureBuilder<LocalStore>(
    future: loading,
    builder: (context, s) {
      if (s.hasData) return AppShell(store: s.data!);
      if (s.hasError) {
        return Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Unable to open local storage: ${s.error}'),
                  FilledButton(
                    onPressed: () => setState(() {
                      loading = LocalStore.open();
                    }),
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
          ),
        );
      }
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    },
  );
}
