import 'dart:io';

import 'package:flutter/material.dart';

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
  late final PageController _controller;
  late int _index;

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
