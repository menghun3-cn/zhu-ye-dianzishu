import 'package:flutter/material.dart';

import 'services/catalog.dart';
import 'services/store.dart';
import 'ui/home.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _Boot());
}

class _Boot extends StatefulWidget {
  const _Boot();

  @override
  State<_Boot> createState() => _BootState();
}

class _BootState extends State<_Boot> {
  Store? _store;
  String? _error;
  String _stage = '初始化…';

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      setState(() => _stage = '读取本地设置…');
      final store = await Store.load();
      setState(() => _stage = '加载书目索引（${11348} 本）…');
      await Catalog.load();
      if (!mounted) return;
      setState(() {
        _store = store;
        _stage = '就绪';
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_store != null) return ZhuYeReader(store: _store!);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: const Color(0xFF2E7D32), useMaterial3: true),
      home: Scaffold(
        body: Center(
          child: _error != null
              ? Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.error_outline, size: 48, color: Colors.redAccent),
                      const SizedBox(height: 12),
                      const Text('启动失败', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      Text(_error!, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12)),
                    ],
                  ),
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.auto_stories, size: 56, color: Color(0xFF2E7D32)),
                    const SizedBox(height: 18),
                    const Text('竹叶阅读', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 18),
                    const SizedBox(width: 180, child: LinearProgressIndicator()),
                    const SizedBox(height: 12),
                    Text(_stage, style: const TextStyle(fontSize: 12, color: Colors.grey)),
                  ],
                ),
        ),
      ),
    );
  }
}

class ZhuYeReader extends StatelessWidget {
  final Store store;
  const ZhuYeReader({super.key, required this.store});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '竹叶阅读',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF2E7D32),
        useMaterial3: true,
        visualDensity: VisualDensity.standard,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: const Color(0xFF2E7D32),
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: HomeShell(store: store),
    );
  }
}
