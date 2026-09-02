import 'dart:convert';

import 'package:app_settings/app_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:torch_light/torch_light.dart';

import 'config.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Edge-to-edge + a transparent system-bar theme: the webview itself already
  // handles every safe-area inset via CSS
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.transparent,
    ),
  );
  runApp(const FuelmetrixHostApp());
}

Future<String> fetchPresignedUrl() async {
  final response = await http.post(
    Uri.parse(presignedUrlEndpoint),
    headers: {'Content-Type': 'application/json'},
    body: jsonEncode({
      'clientId': demoClientId,
      'clientSecret': demoClientSecret,
      'phone': demoPhone,
    }),
  );

  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw Exception(
      'presigned-url request failed: ${response.statusCode} ${response.body}',
    );
  }

  // backend: `{ url: 'http://.../?token=...' }`.
  final body = jsonDecode(response.body) as Map<String, dynamic>;
  final url = body['url'] as String?;
  if (url == null || url.isEmpty) {
    throw Exception('presigned-url response missing "url": $body');
  }
  return url;
}

class FuelmetrixHostApp extends StatelessWidget {
  const FuelmetrixHostApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Fuelmetrix Host (demo)',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: const Color(0xFFFF9522)),
      home: const HostHomeScreen(),
    );
  }
}

class HostHomeScreen extends StatelessWidget {
  const HostHomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Fuelmetrix Host (demo)')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.local_gas_station,
                size: 64,
                color: Color(0xFFFF9522),
              ),
              const SizedBox(height: 16),
              const Text('Flutter main app', textAlign: TextAlign.center),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const MiniappWebViewScreen(),
                    ),
                  );
                },
                icon: Image.asset('images/logo.png', width: 24, height: 24),
                label: const Text('Open mini-app'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class MiniappWebViewScreen extends StatefulWidget {
  const MiniappWebViewScreen({super.key});

  @override
  State<MiniappWebViewScreen> createState() => _MiniappWebViewScreenState();
}

class _MiniappWebViewScreenState extends State<MiniappWebViewScreen> {
  double _progress = 0;
  InAppWebViewController? _controller;

  // Presigned-URL fetch state — see fetchPresignedUrl() above. build() below
  // branches on these: null/null = loading, error set = failed (show retry),
  // url set = ready to render the WebView.
  String? _resolvedUrl;
  Object? _fetchError;

  @override
  void initState() {
    super.initState();
    _loadPresignedUrl();
  }

  Future<void> _loadPresignedUrl() async {
    setState(() {
      _resolvedUrl = null;
      _fetchError = null;
    });
    try {
      final url = await fetchPresignedUrl();
      if (mounted) setState(() => _resolvedUrl = url);
    } catch (error) {
      if (mounted) setState(() => _fetchError = error);
    }
  }

  // Miniapp дотоод дэлгэцүүд (Refuel > SelectPump > ...) нь
  // browser history WebView-ийн native goBack()/canGoBack() яг энэ
  // stack-ыг ашигладаг тул системийн буцах дохио эхлээд WebView дотор
  // буцаж, зөвхөн буцах газаргүй болсон үед л энэ Flutter route хаагдаж
  // miniapp хаагдах logic
  Future<void> _handleBackGesture() async {
    final controller = _controller;
    if (controller == null) {
      if (mounted) Navigator.of(context).pop();
      return;
    }

    final currentUrl = await controller.getUrl();
    final path = currentUrl?.path ?? '';
    final isHome = path.isEmpty || path == '/';
    if (!isHome && await controller.canGoBack()) {
      controller.goBack();
      return;
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    if (_fetchError != null) {
      return Scaffold(
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline, size: 48, color: Colors.red),
                  const SizedBox(height: 16),
                  const Text(
                    'Failed to authenticate with the mini-app backend.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '$_fetchError',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _loadPresignedUrl,
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    if (_resolvedUrl == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _handleBackGesture();
      },
      child: Scaffold(
        body: Stack(
          children: [
            InAppWebView(
              initialUrlRequest: URLRequest(url: WebUri(_resolvedUrl!)),
              initialSettings: InAppWebViewSettings(
                mediaPlaybackRequiresUserGesture: false,
                allowsInlineMediaPlayback: true,
                geolocationEnabled: true,
                javaScriptEnabled: true,
                domStorageEnabled: true,
              ),
              onWebViewCreated: (controller) {
                _controller = controller;
                // Close miniapp handler
                controller.addJavaScriptHandler(
                  handlerName: 'closeMiniapp',
                  callback: (args) {
                    if (mounted) Navigator.of(context).pop();
                    return null;
                  },
                );
                // Torch/flashlight function
                controller.addJavaScriptHandler(
                  handlerName: 'setTorch',
                  callback: (args) async {
                    final on = args.isNotEmpty && args[0] == true;
                    try {
                      if (on) {
                        await TorchLight.enableTorch();
                      } else {
                        await TorchLight.disableTorch();
                      }
                      return {'ok': true};
                    } catch (e) {
                      return {'ok': false, 'error': e.toString()};
                    }
                  },
                );
                // Webees location asaagagui uyd location assaah tohirgooni hesgig neeh
                controller.addJavaScriptHandler(
                  handlerName: 'openLocationSettings',
                  callback: (args) async {
                    try {
                      await AppSettings.openAppSettings(
                        type: AppSettingsType.location,
                      );
                      return {'ok': true};
                    } catch (e) {
                      return {'ok': false, 'error': e.toString()};
                    }
                  },
                );
                // OS түвшний Location Services toggle-ийг шууд, тэр даруй shalgah —
                // web navigator.geolocation-д delay garaad bga tul ashiglav
                controller.addJavaScriptHandler(
                  handlerName: 'isLocationServicesEnabled',
                  callback: (args) async {
                    try {
                      final enabled =
                          await geo.Geolocator.isLocationServiceEnabled();
                      return {'enabled': enabled};
                    } catch (e) {
                      return {'enabled': true, 'error': e.toString()};
                    }
                  },
                );
              },
              onProgressChanged: (controller, progress) {
                setState(() => _progress = progress / 100);
              },
              // Камер/микрофоны зөвшөөрөл — QR scanner-т (getUserMedia) хэрэгтэй
              onPermissionRequest: (controller, request) async {
                final wantsCamera = request.resources.contains(
                  PermissionResourceType.CAMERA,
                );
                final wantsMic = request.resources.contains(
                  PermissionResourceType.MICROPHONE,
                );
                if (wantsCamera) {
                  final status = await ph.Permission.camera.request();
                  if (!status.isGranted) {
                    return PermissionResponse(
                      resources: request.resources,
                      action: PermissionResponseAction.DENY,
                    );
                  }
                }
                if (wantsMic) {
                  final status = await ph.Permission.microphone.request();
                  if (!status.isGranted) {
                    return PermissionResponse(
                      resources: request.resources,
                      action: PermissionResponseAction.DENY,
                    );
                  }
                }
                return PermissionResponse(
                  resources: request.resources,
                  action: PermissionResponseAction.GRANT,
                );
              },
              // Байршлын зөвшөөрөл — station хайхад (navigator.geolocation.watchPosition)
              // хэрэгтэй. Дээрх камер шиг л native-runtime зөвшөөрөл: эхлээд
              // permission_handler-аар асууж, OS бодитоор зөвшөөрсөн үед л WebView-д
              // "зөвшөөрөгдсөн" гэж хэлнэ.
              // retain заавал false байх ёстой.(retain: true uyd gantshan udaa duudagdaj bsn)
              onGeolocationPermissionsShowPrompt: (controller, origin) async {
                final status = await ph.Permission.location.request();
                return GeolocationPermissionShowPromptResponse(
                  origin: origin,
                  allow: status.isGranted,
                  retain: false,
                );
              },
            ),
            // Positioned below the status bar explicitly, since the WebView
            // itself now draws edge-to-edge
            if (_progress < 1)
              Positioned(
                top: MediaQuery.of(context).padding.top,
                left: 0,
                right: 0,
                child: LinearProgressIndicator(value: _progress, minHeight: 2),
              ),
          ],
        ),
      ),
    );
  }
}
