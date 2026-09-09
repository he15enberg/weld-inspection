// weldz: aim, capture, send, read the numbers.
//
// One persistent ARSession backs the preview, so a capture is a grab of the
// current ARFrame -- RGB and LiDAR depth from the same instant. Those bytes go
// straight to the server, which segments, measures and draws. The phone does no
// inference and no coordinate arithmetic.

import 'package:flutter/material.dart';

import 'api.dart';
import 'ar_preview.dart';
import 'capture.dart';
import 'result.dart';
import 'settings.dart';

void main() => runApp(const WeldzApp());

class WeldzApp extends StatelessWidget {
  const WeldzApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Weldz',
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(useMaterial3: true),
        home: const HomePage(),
      );
}

enum _Mode { live, busy, result }

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _source = CaptureSource();

  _Mode _mode = _Mode.live;
  String _status = '';
  String _serverUrl = '';
  Report? _report;

  @override
  void initState() {
    super.initState();
    Settings.load().then((u) {
      if (mounted) setState(() => _serverUrl = u);
    });
  }

  Future<void> _capture() async {
    if (_serverUrl.isEmpty) {
      await _editServer();
      if (_serverUrl.isEmpty) return;
    }

    setState(() {
      _mode = _Mode.busy;
      _status = 'Capturing frame…';
    });

    try {
      final shot = await _source.grab();

      if (!mounted) return;
      setState(() => _status =
          'Uploading ${(shot.bytes / 1024).round()} kB and measuring…');

      final report = await Api(_serverUrl).measure(shot);

      if (!mounted) return;
      setState(() {
        _report = report;
        _mode = _Mode.result;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _mode = _Mode.live);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e'), duration: const Duration(seconds: 5)),
      );
    }
  }

  Future<void> _editServer() async {
    final controller = TextEditingController(text: _serverUrl);
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Server URL'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: const InputDecoration(
            hintText: 'abc-def.trycloudflare.com',
            helperText: 'https:// is assumed if you leave it off',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (url == null) return;
    await Settings.save(url);
    if (mounted) setState(() => _serverUrl = url.trim());
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: const Color(0xFF0C1116),
        body: SafeArea(child: _body()),
        floatingActionButton: _mode == _Mode.live
            ? FloatingActionButton.extended(
                onPressed: _capture,
                backgroundColor: const Color(0xFF2F7FF0),
                icon: const Icon(Icons.center_focus_strong),
                label: const Text('Capture'),
              )
            : null,
      );

  Widget _body() {
    switch (_mode) {
      case _Mode.busy:
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 18),
              Text(_status,
                  style: const TextStyle(color: Colors.white70)),
            ],
          ),
        );

      case _Mode.result:
        return ResultView(
          report: _report!,
          onClose: () => setState(() {
            _mode = _Mode.live;
            _report = null;
          }),
        );

      case _Mode.live:
        return Stack(
          children: [
            const Positioned.fill(child: ArPreview()),
            Positioned(
              left: 12,
              top: 12,
              child: GestureDetector(
                onTap: _editServer,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.62),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    _serverUrl.isEmpty ? 'tap to set server' : _serverUrl,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
            ),
          ],
        );
    }
  }
}
