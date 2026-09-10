import 'dart:convert';

import 'package:app_settings/app_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:http/http.dart' as http;
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:torch_light/torch_light.dart';
import 'package:url_launcher/url_launcher.dart' as url_launcher;

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

Future<String> fetchPresignedUrl({
  required String qrCode,
  required String name,
}) async {
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
  final baseUrl = body['url'] as String?;
  if (baseUrl == null || baseUrl.isEmpty) {
    throw Exception('presigned-url response missing "url": $body');
  }

  // Direct QR-scan entry flow: append the natively-scanned pump QR value
  // (plus a display name, informational-only) onto this same presigned URL
  // — a client-side append, not a backend contract change. The webview's
  // App.vue onMounted reads `qrCode` off this exact query string to jump
  // straight to fuel selection instead of showing Home.
  final uri = Uri.parse(baseUrl);
  final merged = uri.replace(
    queryParameters: {...uri.queryParameters, 'qrCode': qrCode, 'name': name},
  );
  final url = merged.toString();
  print(url);
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
                onPressed: () async {
                  // Direct QR-scan entry flow: scan the pump QR natively
                  // first (demoQrCode bypasses the camera for quick testing
                  // — see config.dart), then hand the decoded value + a
                  // display name to the webview via the presigned URL (see
                  // fetchPresignedUrl above).
                  final code =
                      demoQrCode ??
                      await Navigator.of(context).push<String>(
                        MaterialPageRoute(
                          builder: (_) => const QrScanScreen(),
                        ),
                      );
                  if (code == null || code.isEmpty) return;
                  if (!context.mounted) return;
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) =>
                          MiniappWebViewScreen(qrCode: code, name: demoName),
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

// Direct QR-scan entry flow: scans a pump's QR code with the device camera
// (mobile_scanner) before the webview is ever opened — replaces the old
// in-webview getUserMedia scanner (webview/src/pages/refuel/QrScanner.vue,
// still intact but unreachable — see webview/src/router/index.js) for this
// flow. Pops with the decoded raw value, or null if the user backs out.
class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key});

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  // MobileScanner can fire onDetect repeatedly for the same frame/code
  // before the pop actually unmounts this screen — guard against popping
  // more than once.
  bool _handled = false;

  void _onDetect(BarcodeCapture capture) {
    if (_handled || capture.barcodes.isEmpty) return;
    final value = capture.barcodes.first.rawValue;
    if (value == null || value.isEmpty) return;
    _handled = true;
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Scan pump QR code'),
      ),
      body: MobileScanner(onDetect: _onDetect),
    );
  }
}

class MiniappWebViewScreen extends StatefulWidget {
  const MiniappWebViewScreen({
    super.key,
    required this.qrCode,
    required this.name,
  });

  // The natively-scanned pump QR value and a display name — see
  // fetchPresignedUrl() above, which appends both onto the presigned URL.
  final String qrCode;
  final String name;

  @override
  State<MiniappWebViewScreen> createState() => _MiniappWebViewScreenState();
}

class _MiniappWebViewScreenState extends State<MiniappWebViewScreen> {
  double _progress = 0;
  InAppWebViewController? _controller;
  // Доорх Navigator.pop()-г хоёр удаа дуудагдахаас хамгаална — closeMiniapp
  bool _isClosing = false;

  void _popMiniapp() {
    if (_isClosing || !mounted) return;
    _isClosing = true;
    Navigator.of(context).pop();
  }

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
      final url = await fetchPresignedUrl(
        qrCode: widget.qrCode,
        name: widget.name,
      );
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
      _popMiniapp();
      return;
    }

    final currentUrl = await controller.getUrl();
    final path = currentUrl?.path ?? '';
    final isHome = path.isEmpty || path == '/';
    if (!isHome && await controller.canGoBack()) {
      controller.goBack();
      return;
    }
    _popMiniapp();
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
        // Matches webview/src/theme.js's `background` token — Android's
        // native WebView defaults to a black canvas until the page's first
        // paint lands, so without this the black WebView briefly shows
        // through on any slow load (cold Vite compile, slow network) before
        // transparentBackground below lets this color show instead.
        backgroundColor: const Color(0xFFF4F6F8),
        body: Stack(
          children: [
            Container(
              color: const Color(0xFFF4F6F8),
              child: InAppWebView(
                initialUrlRequest: URLRequest(url: WebUri(_resolvedUrl!)),
                initialSettings: InAppWebViewSettings(
                  mediaPlaybackRequiresUserGesture: false,
                  allowsInlineMediaPlayback: true,
                  geolocationEnabled: true,
                  javaScriptEnabled: true,
                  domStorageEnabled: true,
                  transparentBackground: true,
                ),
                onWebViewCreated: (controller) {
                  _controller = controller;
                  // Close miniapp handler
                  controller.addJavaScriptHandler(
                    handlerName: 'closeMiniapp',
                    callback: (args) {
                      _popMiniapp();
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
                  // Neither iOS nor Android has a deep link straight to a
                  // per-permission camera settings screen the way Android has
                  // for Location — AppSettingsType.settings opens this app's
                  // own Settings entry instead (Settings > <app> on iOS,
                  // the App Info page on Android), where the Camera toggle
                  // lives alongside every other permission. That's the
                  // standard recovery path once a user has denied camera
                  // permission and the OS won't re-prompt from JS anymore.
                  controller.addJavaScriptHandler(
                    handlerName: 'openCameraSettings',
                    callback: (args) async {
                      try {
                        await AppSettings.openAppSettings(
                          type: AppSettingsType.settings,
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
                  // Bank app deep link (khanbank://, socialpay-payment://, ...)
                  // neeh. window.location.href-eer shuud daaruulbal WebView
                  // dotor "webpage not found" gej aldaa garj bsn bolhor ingej hiile
                  controller.addJavaScriptHandler(
                    handlerName: 'openExternalUrl',
                    callback: (args) async {
                      final urlString = args.isNotEmpty
                          ? args[0] as String?
                          : null;
                      if (urlString == null || urlString.isEmpty) {
                        return {'ok': false};
                      }
                      try {
                        final uri = Uri.parse(urlString);
                        final launched = await url_launcher.launchUrl(
                          uri,
                          mode: url_launcher.LaunchMode.externalApplication,
                        );
                        return {'ok': launched};
                      } catch (e) {
                        return {'ok': false, 'error': e.toString()};
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
