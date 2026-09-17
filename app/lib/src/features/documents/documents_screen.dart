import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/api_client.dart';
import '../../core/models.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

class DocumentsScreen extends StatefulWidget {
  const DocumentsScreen({super.key});

  @override
  State<DocumentsScreen> createState() => _DocumentsScreenState();
}

class _DocumentsScreenState extends State<DocumentsScreen> {
  bool loading = true;
  List<Map<String, dynamic>> items = [];

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final response = await ApiClient.instance.dio.get('/documents');
      items = List<Map<String, dynamic>>.from(response.data as List);
    } catch (error) {
      if (mounted) {
        AppNotice.show(
          context,
          ApiClient.instance.errorMessage(error),
          error: true,
        );
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              PageHeader(
                title: 'Documents',
                subtitle:
                    'Upload a file, verify your signature, and create an electronic signed copy.',
                trailing: IconButton.filledTonal(
                  tooltip: 'Upload document',
                  onPressed: upload,
                  icon: const Icon(Icons.upload_file_rounded),
                ),
              ),
              const SizedBox(height: 22),
              Expanded(
                child: loading
                    ? const Center(child: CircularProgressIndicator())
                    : items.isEmpty
                        ? const EmptyState(
                            icon: Icons.folder_off_outlined,
                            title: 'No documents yet',
                            message:
                                'Upload a document, then sign it with your verified behavioral signature.',
                          )
                        : RefreshIndicator(
                            onRefresh: load,
                            child: ListView.separated(
                              itemCount: items.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(height: 10),
                              itemBuilder: (_, index) =>
                                  documentTile(items[index]),
                            ),
                          ),
              ),
            ],
          ),
        ),
      );

  Widget documentTile(Map<String, dynamic> item) {
    final shared = item['is_shared_with_admin'] == true;
    final signed = item['is_signed'] == true;

    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(19),
      child: InkWell(
        borderRadius: BorderRadius.circular(19),
        onTap: () => openDocument(item),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: signed
                      ? AppColors.success.withValues(alpha: .10)
                      : AppColors.tealLight,
                  borderRadius: BorderRadius.circular(15),
                ),
                child: Icon(
                  signed
                      ? Icons.verified_rounded
                      : Icons.description_outlined,
                  color: signed ? AppColors.success : AppColors.teal,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item['original_name'] as String? ?? 'Document',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${formatBytes((item['size_bytes'] as num).toInt())}  •  '
                      '${signed ? 'Signed' : 'Not signed'}'
                      '${shared ? '  •  Shared' : ''}',
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                onSelected: (value) => action(value, item),
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: 'view',
                    child: Text('Open document'),
                  ),
                  if (!signed)
                    const PopupMenuItem(
                      value: 'sign',
                      child: Text('Sign document'),
                    ),
                  if (signed)
                    PopupMenuItem(
                      value: shared ? 'unshare' : 'share',
                      child: Text(
                        shared
                            ? 'Stop sharing'
                            : 'Share with local administrator',
                      ),
                    ),
                  const PopupMenuItem(
                    value: 'delete',
                    child: Text('Delete securely'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String formatBytes(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024).clamp(0, double.infinity).toStringAsFixed(0)} KB';
  }

  Future<void> upload() async {
    final picked = await FilePicker.platform.pickFiles(withData: true);
    if (picked == null || picked.files.single.bytes == null) return;

    final file = picked.files.single;
    try {
      await ApiClient.instance.uploadDocument(
        fileName: file.name,
        bytes: file.bytes!,
      );
      if (mounted) {
        AppNotice.show(context, 'Document encrypted and saved locally.');
        setState(() => loading = true);
      }
      await load();
    } catch (error) {
      if (mounted) {
        AppNotice.show(
          context,
          ApiClient.instance.errorMessage(error),
          error: true,
        );
      }
    }
  }

  Future<void> openDocument(Map<String, dynamic> item) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => DocumentViewerScreen(document: item),
      ),
    );
    if (mounted) {
      setState(() => loading = true);
      await load();
    }
  }

  Future<void> action(
    String selectedAction,
    Map<String, dynamic> item,
  ) async {
    if (selectedAction == 'view') {
      await openDocument(item);
      return;
    }

    if (selectedAction == 'sign') {
      final updated = await Navigator.of(context).push<Map<String, dynamic>>(
        MaterialPageRoute(
          builder: (_) => DocumentSigningScreen(document: item),
        ),
      );
      if (updated != null && mounted) {
        AppNotice.show(context, 'Signed document created successfully.');
        setState(() => loading = true);
        await load();
      }
      return;
    }

    if (selectedAction == 'delete') {
      final confirmed = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => const ConfirmationPage(
            title: 'Delete this document?',
            message:
                'The encrypted original, electronic signature, and signed copy will be removed permanently.',
            confirmLabel: 'Delete securely',
            destructive: true,
          ),
        ),
      );
      if (confirmed != true) return;
    }

    try {
      if (selectedAction == 'delete') {
        await ApiClient.instance.dio.delete('/documents/${item['id']}');
      } else {
        await ApiClient.instance.dio.post(
          '/documents/${item['id']}/$selectedAction',
        );
      }
      if (mounted) setState(() => loading = true);
      await load();
    } catch (error) {
      if (mounted) {
        AppNotice.show(
          context,
          ApiClient.instance.errorMessage(error),
          error: true,
        );
      }
    }
  }
}

class DocumentViewerScreen extends StatefulWidget {
  final Map<String, dynamic> document;
  final bool administrator;

  const DocumentViewerScreen({
    super.key,
    required this.document,
    this.administrator = false,
  });

  @override
  State<DocumentViewerScreen> createState() => _DocumentViewerScreenState();
}

class _DocumentViewerScreenState extends State<DocumentViewerScreen> {
  late Map<String, dynamic> document;
  Uint8List? bytes;
  bool loading = true;

  bool get signed => document['is_signed'] == true;

  @override
  void initState() {
    super.initState();
    document = Map<String, dynamic>.from(widget.document);
    load();
  }

  Future<void> load() async {
    setState(() => loading = true);
    try {
      final response = signed
          ? await ApiClient.instance.readSignedDocumentPreview(
              documentId: document['id'] as int,
              administrator: widget.administrator,
            )
          : await ApiClient.instance.readDocumentOriginal(
              documentId: document['id'] as int,
              administrator: widget.administrator,
            );
      bytes = response.data;
    } catch (error) {
      if (mounted) {
        AppNotice.show(
          context,
          ApiClient.instance.errorMessage(error),
          error: true,
        );
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
          appBar: AppBar(
            title: Text(signed ? 'Signed document' : 'Document'),
            leading: IconButton(
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.arrow_back_rounded),
            ),
          ),
          body: SafeArea(
            child: Column(
              children: [
                Expanded(
                  child: loading
                      ? const Center(child: CircularProgressIndicator())
                      : _DocumentContent(
                          bytes: bytes,
                          mimeType: signed
                              ? 'image/png'
                              : document['mime_type'] as String? ??
                                  'application/octet-stream',
                          fileName:
                              document['original_name'] as String? ?? 'Document',
                          signed: signed,
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 22),
                  child: Column(
                    children: [
                      if (widget.administrator) ...[
                        _InfoRow(
                          label: 'Owner',
                          value: document['owner_name'] as String? ??
                              'User ${document['owner_id']}',
                        ),
                        _InfoRow(
                          label: 'Email',
                          value: document['owner_email'] as String? ?? '—',
                        ),
                      ],
                      _InfoRow(
                        label: 'Status',
                        value: signed ? 'Electronically signed' : 'Not signed',
                      ),
                      if (signed)
                        _InfoRow(
                          label: 'Verification confidence',
                          value:
                              '${(((document['signature_probability'] as num?)?.toDouble() ?? 0) * 100).toStringAsFixed(1)}%',
                        ),
                      if (!widget.administrator) ...[
                        const SizedBox(height: 12),
                        if (!signed)
                          FilledButton.icon(
                            onPressed: signDocument,
                            icon: const Icon(Icons.draw_rounded),
                            label: const Text('Sign this document'),
                          )
                        else
                          OutlinedButton.icon(
                            onPressed: toggleSharing,
                            icon: Icon(
                              document['is_shared_with_admin'] == true
                                  ? Icons.lock_outline_rounded
                                  : Icons.share_outlined,
                            ),
                            label: Text(
                              document['is_shared_with_admin'] == true
                                  ? 'Stop sharing with administrator'
                                  : 'Share with administrator',
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        );

  Future<void> signDocument() async {
    final updated = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(
        builder: (_) => DocumentSigningScreen(document: document),
      ),
    );
    if (updated == null || !mounted) return;

    setState(() {
      document = updated;
    });
    await load();
    if (mounted) {
      AppNotice.show(context, 'Signed document created successfully.');
    }
  }

  Future<void> toggleSharing() async {
    final shared = document['is_shared_with_admin'] == true;
    try {
      final response = await ApiClient.instance.dio.post(
        '/documents/${document['id']}/${shared ? 'unshare' : 'share'}',
      );
      if (!mounted) return;
      setState(() {
        document = Map<String, dynamic>.from(response.data as Map);
        });
      AppNotice.show(
        context,
        shared
            ? 'Document is no longer shared.'
            : 'Signed document shared with the local administrator.',
      );
    } catch (error) {
      if (mounted) {
        AppNotice.show(
          context,
          ApiClient.instance.errorMessage(error),
          error: true,
        );
      }
    }
  }
}

class DocumentSigningScreen extends StatefulWidget {
  final Map<String, dynamic> document;

  const DocumentSigningScreen({
    super.key,
    required this.document,
  });

  @override
  State<DocumentSigningScreen> createState() => _DocumentSigningScreenState();
}

class _DocumentSigningScreenState extends State<DocumentSigningScreen> {
  bool busy = false;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Sign document')),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
            child: Column(
              children: [
                const Spacer(),
                const Icon(
                  Icons.draw_rounded,
                  color: AppColors.teal,
                  size: 82,
                ),
                const SizedBox(height: 24),
                Text(
                  widget.document['original_name'] as String? ?? 'Document',
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 12),
                Text(
                  'Your new signature will be verified against the five stored references. A signed copy is created only when the signature is accepted.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                const Spacer(),
                FilledButton.icon(
                  onPressed: busy ? null : captureAndSign,
                  icon: const Icon(Icons.fingerprint_rounded),
                  label: Text(
                    busy ? 'Verifying and signing...' : 'Capture signature',
                  ),
                ),
              ],
            ),
          ),
        ),
      );

  Future<void> captureAndSign() async {
    final captured = await context.push<CapturedSignature>(
      '/capture?title=Sign%20document',
    );
    if (captured == null || !mounted) return;

    setState(() => busy = true);
    try {
      final response = await ApiClient.instance.dio.post(
        '/documents/${widget.document['id']}/sign',
        data: {'signature': captured.toJson()},
      );
      if (mounted) {
        Navigator.pop(
          context,
          Map<String, dynamic>.from(response.data as Map),
        );
      }
    } catch (error) {
      if (mounted) {
        AppNotice.show(
          context,
          ApiClient.instance.errorMessage(error),
          error: true,
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }
}

class _DocumentContent extends StatelessWidget {
  final Uint8List? bytes;
  final String mimeType;
  final String fileName;
  final bool signed;

  const _DocumentContent({
    required this.bytes,
    required this.mimeType,
    required this.fileName,
    required this.signed,
  });

  @override
  Widget build(BuildContext context) {
    final data = bytes;
    if (data == null || data.isEmpty) {
      return const EmptyState(
        icon: Icons.broken_image_outlined,
        title: 'Preview unavailable',
        message: 'The document content could not be displayed.',
      );
    }

    if (signed || mimeType.startsWith('image/')) {
      return InteractiveViewer(
        minScale: .7,
        maxScale: 4,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Image.memory(
              data,
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) => const EmptyState(
                icon: Icons.broken_image_outlined,
                title: 'Preview unavailable',
                message: 'The image could not be decoded.',
              ),
            ),
          ),
        ),
      );
    }

    if (mimeType == 'text/plain') {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: SelectableText(
          utf8.decode(data, allowMalformed: true),
          style: Theme.of(context).textTheme.bodyLarge,
        ),
      );
    }

    return EmptyState(
      icon: Icons.description_outlined,
      title: fileName,
      message:
          'The encrypted original is stored locally. Sign the document to generate a viewable electronic signed copy.',
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;

  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Expanded(child: Text(label)),
            Flexible(
              child: Text(
                value,
                textAlign: TextAlign.end,
                style: const TextStyle(
                  color: AppColors.ink,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      );
}

class ConfirmationPage extends StatelessWidget {
  final String title;
  final String message;
  final String confirmLabel;
  final bool destructive;

  const ConfirmationPage({
    super.key,
    required this.title,
    required this.message,
    required this.confirmLabel,
    this.destructive = false,
  });

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              children: [
                const Spacer(),
                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: (destructive ? AppColors.danger : AppColors.teal)
                        .withValues(alpha: .1),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    destructive
                        ? Icons.delete_forever_outlined
                        : Icons.help_outline_rounded,
                    color: destructive ? AppColors.danger : AppColors.teal,
                    size: 58,
                  ),
                ),
                const SizedBox(height: 26),
                Text(
                  title,
                  style: Theme.of(context).textTheme.headlineMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                const Spacer(),
                FilledButton(
                  style: destructive
                      ? FilledButton.styleFrom(
                          backgroundColor: AppColors.danger,
                        )
                      : null,
                  onPressed: () => Navigator.pop(context, true),
                  child: Text(confirmLabel),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ),
        ),
      );
}
