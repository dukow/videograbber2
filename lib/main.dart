import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:webview_flutter/webview_flutter.dart';

void main() {
  runApp(const VideoGrabberApp());
}

class VideoGrabberApp extends StatelessWidget {
  const VideoGrabberApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Video Grabber',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0F1115),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF7C4DFF),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const MainShell(),
    );
  }
}

/// ---------------------------------------------------------------------------
/// Shared downloader service (talks to native yt-dlp)
/// ---------------------------------------------------------------------------
class Downloader {
  static const channel = MethodChannel('video_grabber/downloader');
  static const progressChannel = EventChannel('video_grabber/progress');

  static Future<Map<String, dynamic>?> getInfo(String url) async {
    return channel.invokeMapMethod<String, dynamic>('getInfo', {'url': url});
  }

  static Future<String?> download(String url, String quality) async {
    return channel
        .invokeMethod<String>('download', {'url': url, 'quality': quality});
  }

  static Future<void> updateEngine() async {
    await channel.invokeMethod('updateEngine');
  }

  static Future<String?> getSharedUrl() async {
    try {
      return await channel.invokeMethod<String>('getSharedUrl');
    } catch (_) {
      return null;
    }
  }
}

/// ---------------------------------------------------------------------------
/// Main shell with bottom tabs
/// ---------------------------------------------------------------------------
class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _tab = 0;
  final _downloaderKey = GlobalKey<_DownloaderPageState>();

  @override
  void initState() {
    super.initState();
    _requestPermissions();
  }

  Future<void> _requestPermissions() async {
    await [
      Permission.storage,
      Permission.manageExternalStorage,
      Permission.notification,
    ].request();
  }

  void openInDownloader(String url) {
    setState(() => _tab = 0);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _downloaderKey.currentState?.loadUrl(url);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _tab,
        children: [
          DownloaderPage(key: _downloaderKey),
          BrowserPage(onDownloadRequest: openInDownloader),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.download), label: 'Downloader'),
          NavigationDestination(icon: Icon(Icons.public), label: 'Browser'),
        ],
      ),
    );
  }
}

/// ---------------------------------------------------------------------------
/// TAB 1: Paste-link downloader
/// ---------------------------------------------------------------------------
class DownloaderPage extends StatefulWidget {
  const DownloaderPage({super.key});

  @override
  State<DownloaderPage> createState() => _DownloaderPageState();
}

class _DownloaderPageState extends State<DownloaderPage> {
  final TextEditingController _urlController = TextEditingController();

  Map<String, dynamic>? _videoInfo;
  bool _loadingInfo = false;
  bool _downloading = false;
  double _progress = 0;
  String _eta = '';
  String _status = '';
  String? _savedPath;
  StreamSubscription? _progressSub;

  @override
  void initState() {
    super.initState();
    _checkSharedUrl();
    _progressSub =
        Downloader.progressChannel.receiveBroadcastStream().listen((event) {
      if (event is Map) {
        setState(() {
          _progress = (event['progress'] as num?)?.toDouble() ?? 0;
          final etaSec = (event['eta'] as num?)?.toInt() ?? 0;
          _eta = etaSec > 0 ? '${etaSec}s left' : '';
        });
      }
    });
  }

  Future<void> _checkSharedUrl() async {
    final shared = await Downloader.getSharedUrl();
    if (shared != null && shared.isNotEmpty) {
      loadUrl(shared);
    }
  }

  void loadUrl(String url) {
    _urlController.text = url.trim();
    _fetchInfo();
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null) {
      loadUrl(data!.text!);
    }
  }

  Future<void> _fetchInfo() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;
    setState(() {
      _loadingInfo = true;
      _videoInfo = null;
      _savedPath = null;
      _status = 'Getting video info...';
    });
    try {
      final result = await Downloader.getInfo(url);
      setState(() {
        _videoInfo = result;
        _status = '';
      });
    } on PlatformException catch (e) {
      setState(() => _status = 'Error: ${e.message}');
    } finally {
      setState(() => _loadingInfo = false);
    }
  }

  Future<void> _download(String quality) async {
    final url = _urlController.text.trim();
    if (url.isEmpty || _downloading) return;
    final label = quality == 'mp3' ? 'MP3 audio' : '${quality}p video';
    setState(() {
      _downloading = true;
      _progress = 0;
      _savedPath = null;
      _status = 'Downloading $label...';
    });
    try {
      final path = await Downloader.download(url, quality);
      setState(() {
        _savedPath = path;
        _status = 'Saved successfully!';
        _progress = 100;
      });
    } on PlatformException catch (e) {
      setState(() => _status = 'Download failed: ${e.message}');
    } finally {
      setState(() => _downloading = false);
    }
  }

  Future<void> _updateEngine() async {
    setState(() => _status = 'Updating yt-dlp engine...');
    try {
      await Downloader.updateEngine();
      setState(() => _status = 'Engine updated!');
    } on PlatformException catch (e) {
      setState(() => _status = 'Update failed: ${e.message}');
    }
  }

  @override
  void dispose() {
    _progressSub?.cancel();
    _urlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Video Grabber',
            style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.transparent,
        actions: [
          IconButton(
            tooltip: 'Update yt-dlp engine',
            icon: const Icon(Icons.system_update_alt),
            onPressed: _downloading ? null : _updateEngine,
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _urlController,
              decoration: InputDecoration(
                hintText: 'Paste video link here...',
                filled: true,
                fillColor: const Color(0xFF1A1D24),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.content_paste),
                  onPressed: _pasteFromClipboard,
                ),
              ),
              onSubmitted: (_) => _fetchInfo(),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _loadingInfo || _downloading ? null : _fetchInfo,
              icon: _loadingInfo
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.search),
              label: const Text('Get Video'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
            ),
            if (_videoInfo != null) ...[
              const SizedBox(height: 20),
              Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF1A1D24),
                  borderRadius: BorderRadius.circular(16),
                ),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    if ((_videoInfo!['thumbnail'] ?? '').toString().isNotEmpty)
                      Image.network(
                        _videoInfo!['thumbnail'],
                        width: double.infinity,
                        height: 200,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => const SizedBox(),
                      ),
                    Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _videoInfo!['title'] ?? 'Unknown title',
                            style: const TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '${_videoInfo!['uploader'] ?? ''}'
                            '${_videoInfo!['duration'] != null ? '  •  ${_formatDuration(_videoInfo!['duration'])}' : ''}',
                            style: TextStyle(
                                fontSize: 13, color: Colors.grey[400]),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _downloading ? null : () => _download('720'),
                      icon: const Icon(Icons.hd),
                      label: const Text('720p'),
                      style: _btnStyle(),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _downloading ? null : () => _download('1080'),
                      icon: const Icon(Icons.high_quality),
                      label: const Text('1080p'),
                      style: _btnStyle(),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _downloading ? null : () => _download('mp3'),
                      icon: const Icon(Icons.music_note),
                      label: const Text('MP3'),
                      style: _btnStyle(),
                    ),
                  ),
                ],
              ),
            ],
            if (_downloading) ...[
              const SizedBox(height: 24),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  value: _progress > 0 ? _progress / 100 : null,
                  minHeight: 10,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '${_progress.toStringAsFixed(1)}%  $_eta',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey[400]),
              ),
            ],
            if (_status.isNotEmpty) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: _savedPath != null
                      ? Colors.green.withOpacity(0.15)
                      : const Color(0xFF1A1D24),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  children: [
                    Text(_status, textAlign: TextAlign.center),
                    if (_savedPath != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        _savedPath!,
                        textAlign: TextAlign.center,
                        style:
                            TextStyle(fontSize: 12, color: Colors.grey[500]),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  ButtonStyle _btnStyle() => OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      );

  String _formatDuration(dynamic seconds) {
    final s = (seconds as num).toInt();
    final m = s ~/ 60;
    final sec = s % 60;
    if (m >= 60) return '${m ~/ 60}h ${m % 60}m';
    return '${m}m ${sec}s';
  }
}

/// ---------------------------------------------------------------------------
/// TAB 2: In-app browser with floating download button
/// ---------------------------------------------------------------------------
class BrowserPage extends StatefulWidget {
  final void Function(String url) onDownloadRequest;
  const BrowserPage({super.key, required this.onDownloadRequest});

  @override
  State<BrowserPage> createState() => _BrowserPageState();
}

class _BrowserPageState extends State<BrowserPage> {
  late final WebViewController _controller;
  final TextEditingController _addressController =
      TextEditingController(text: 'https://m.youtube.com');
  double _loadProgress = 0;
  String _currentUrl = 'https://m.youtube.com';

  static const _shortcuts = <String, String>{
    'YouTube': 'https://m.youtube.com',
    'TikTok': 'https://www.tiktok.com',
    'Facebook': 'https://m.facebook.com/watch',
    'Instagram': 'https://www.instagram.com/reels',
    'Twitter/X': 'https://x.com',
    'Dailymotion': 'https://www.dailymotion.com',
  };

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (p) => setState(() => _loadProgress = p / 100),
          onPageStarted: (url) => setState(() {
            _currentUrl = url;
            _addressController.text = url;
          }),
          onPageFinished: (url) => setState(() {
            _currentUrl = url;
            _addressController.text = url;
            _loadProgress = 0;
          }),
          onUrlChange: (change) {
            final u = change.url;
            if (u != null) {
              setState(() {
                _currentUrl = u;
                _addressController.text = u;
              });
            }
          },
        ),
      )
      ..loadRequest(Uri.parse(_currentUrl));
  }

  void _go() {
    var input = _addressController.text.trim();
    if (input.isEmpty) return;
    if (!input.startsWith('http')) {
      if (input.contains('.') && !input.contains(' ')) {
        input = 'https://$input';
      } else {
        input = 'https://www.google.com/search?q=${Uri.encodeComponent(input)}';
      }
    }
    _controller.loadRequest(Uri.parse(input));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        titleSpacing: 8,
        title: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back, size: 20),
              onPressed: () async {
                if (await _controller.canGoBack()) _controller.goBack();
              },
            ),
            Expanded(
              child: SizedBox(
                height: 40,
                child: TextField(
                  controller: _addressController,
                  style: const TextStyle(fontSize: 13),
                  decoration: InputDecoration(
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 12),
                    filled: true,
                    fillColor: const Color(0xFF1A1D24),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  onSubmitted: (_) => _go(),
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.refresh, size: 20),
              onPressed: () => _controller.reload(),
            ),
          ],
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(40),
          child: Column(
            children: [
              if (_loadProgress > 0 && _loadProgress < 1)
                LinearProgressIndicator(value: _loadProgress, minHeight: 2),
              SizedBox(
                height: 36,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  children: _shortcuts.entries
                      .map((e) => Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: ActionChip(
                              label: Text(e.key,
                                  style: const TextStyle(fontSize: 12)),
                              onPressed: () =>
                                  _controller.loadRequest(Uri.parse(e.value)),
                            ),
                          ))
                      .toList(),
                ),
              ),
            ],
          ),
        ),
      ),
      body: WebViewWidget(controller: _controller),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => widget.onDownloadRequest(_currentUrl),
        icon: const Icon(Icons.download),
        label: const Text('Download'),
      ),
    );
  }
}
