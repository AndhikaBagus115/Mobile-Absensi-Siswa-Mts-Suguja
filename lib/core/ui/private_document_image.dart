import 'package:flutter/material.dart';

import '../../data/services/private_document_service.dart';

/// Resolve a short-lived URL on each open; never store signed URLs in models.
class PrivateDocumentImage extends StatefulWidget {
  const PrivateDocumentImage(
    this.reference, {
    super.key,
    this.fit,
    this.height,
    this.width,
    this.loadingBuilder,
    this.errorBuilder,
  });

  final String reference;
  final BoxFit? fit;
  final double? height;
  final double? width;
  final ImageLoadingBuilder? loadingBuilder;
  final ImageErrorWidgetBuilder? errorBuilder;

  @override
  State<PrivateDocumentImage> createState() => _PrivateDocumentImageState();
}

class _PrivateDocumentImageState extends State<PrivateDocumentImage> {
  late Future<String> _signedUrl;

  @override
  void initState() {
    super.initState();
    _signedUrl = PrivateDocumentService().signedUrl(widget.reference);
  }

  @override
  void didUpdateWidget(covariant PrivateDocumentImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reference != widget.reference) {
      _signedUrl = PrivateDocumentService().signedUrl(widget.reference);
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<String>(
    future: _signedUrl,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return widget.errorBuilder?.call(
              context,
              StateError('Lampiran tidak tersedia atau akses ditolak.'),
              null,
            ) ??
            const Center(
              child: Text('Lampiran tidak tersedia atau akses ditolak.'),
            );
      }
      if (!snapshot.hasData) {
        return SizedBox(
          height: widget.height,
          width: widget.width,
          child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        );
      }
      return Image.network(
        snapshot.data!,
        fit: widget.fit,
        height: widget.height,
        width: widget.width,
        loadingBuilder: widget.loadingBuilder,
        errorBuilder: widget.errorBuilder,
      );
    },
  );
}
