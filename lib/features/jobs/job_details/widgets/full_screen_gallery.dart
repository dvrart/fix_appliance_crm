import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../../../../core/app_feedback.dart';
import '../../../../core/l10n/app_locale.dart';
import '../../../../core/utils/thumb_image.dart';

class FullScreenGallery extends StatefulWidget {
  final List<Map<String, dynamic>> images;
  final int initialIndex;

  const FullScreenGallery({
    super.key,
    required this.images,
    this.initialIndex = 0,
  });

  @override
  State<FullScreenGallery> createState() => _FullScreenGalleryState();
}

class _FullScreenGalleryState extends State<FullScreenGallery> {
  static const MethodChannel _deviceChannel = MethodChannel(
    'fix_appliance/device',
  );

  late final PageController _controller;
  late int _index;
  bool _downloading = false;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, widget.images.length - 1);
    _controller = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  ImageProvider _imageOf(BuildContext context, Map<String, dynamic> item) {
    final local = (item['localPath'] ?? '').toString();
    final url = (item['url'] ?? '').toString();
    final source = local.isNotEmpty && url.isEmpty
        ? FileImage(File(local)) as ImageProvider
        : NetworkImage(url);
    // Полное разрешение здесь не нужно и опасно: см. fullImage.
    return fullImage(
      source,
      logicalWidth: MediaQuery.sizeOf(context).width,
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
    );
  }

  (String, String) _detectFormat(Uint8List bytes, String hint) {
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return ('png', 'image/png');
    }
    if (bytes.length >= 6 &&
        bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46) {
      return ('gif', 'image/gif');
    }
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return ('webp', 'image/webp');
    }
    final lower = hint.toLowerCase();
    if (lower.endsWith('.png')) return ('png', 'image/png');
    if (lower.endsWith('.webp')) return ('webp', 'image/webp');
    if (lower.endsWith('.gif')) return ('gif', 'image/gif');
    return ('jpg', 'image/jpeg');
  }

  Future<Uint8List> _loadBytes(Map<String, dynamic> item) async {
    final local = (item['localPath'] ?? '').toString().trim();
    if (local.isNotEmpty) {
      final file = File(local);
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        if (bytes.isNotEmpty) return bytes;
      }
    }
    final url = (item['url'] ?? '').toString().trim();
    if (url.isEmpty) throw StateError('empty photo source');
    final response = await http
        .get(Uri.parse(url))
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
      throw StateError('http ${response.statusCode}');
    }
    return response.bodyBytes;
  }

  Future<void> _downloadCurrent() async {
    if (_downloading || widget.images.isEmpty) return;
    AppFeedback.pleasant();
    setState(() => _downloading = true);
    try {
      final item = widget.images[_index];
      final bytes = await _loadBytes(item);
      if (!mounted) return;
      final hint =
          (item['name'] ?? item['localPath'] ?? item['url'] ?? '').toString();
      final (ext, mime) = _detectFormat(bytes, hint);
      final now = DateTime.now();
      String two(int v) => v.toString().padLeft(2, '0');
      final fileName =
          'photo_${now.year}-${two(now.month)}-${two(now.day)}_'
          '${two(now.hour)}-${two(now.minute)}-${two(now.second)}.$ext';

      final saveTitle = context.tr('Скачать фото', 'Download photo');
      var saved = false;
      if (Platform.isAndroid) {
        saved =
            await _deviceChannel.invokeMethod<bool>('saveImageToGallery', {
              'bytes': bytes,
              'name': fileName,
              'mimeType': mime,
            }) ??
            false;
      }
      if (!saved) {
        final uri = await FilePicker.saveFile(
          dialogTitle: saveTitle,
          fileName: fileName,
          bytes: bytes,
          mimeType: mime,
        );
        saved = uri != null;
      }
      if (!mounted || !saved) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.tr('Фото скачано', 'Photo downloaded')),
          backgroundColor: Colors.green,
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.tr('Не удалось скачать фото', 'Could not download photo'),
          ),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.images.isEmpty) {
      return const Scaffold(backgroundColor: Colors.black);
    }
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text('${_index + 1} / ${widget.images.length}'),
        actions: [
          IconButton(
            tooltip: context.tr('Скачать фото', 'Download photo'),
            onPressed: _downloading ? null : _downloadCurrent,
            icon: _downloading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.download_rounded),
          ),
        ],
      ),
      body: PageView.builder(
        controller: _controller,
        itemCount: widget.images.length,
        onPageChanged: (index) => setState(() => _index = index),
        itemBuilder: (context, index) {
          return InteractiveViewer(
            minScale: 1.0,
            maxScale: 4.0,
            panEnabled: false,
            child: Center(
              child: Image(
                image: _imageOf(context, widget.images[index]),
                fit: BoxFit.contain,
                errorBuilder: (context, error, stackTrace) {
                  return const Icon(
                    Icons.broken_image,
                    color: Colors.white54,
                    size: 64,
                  );
                },
              ),
            ),
          );
        },
      ),
    );
  }
}
