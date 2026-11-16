import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/app_info_service.dart';

class AppAboutDialog extends ConsumerStatefulWidget {
  const AppAboutDialog({super.key});

  @override
  ConsumerState<AppAboutDialog> createState() => _AppAboutDialogState();
}

class _AppAboutDialogState extends ConsumerState<AppAboutDialog> {
  bool _copying = false;
  bool _copyFailed = false;
  String? _copyMessage;

  Future<void> _copyInfo(AppInfo info) async {
    setState(() {
      _copying = true;
      _copyMessage = null;
    });
    try {
      await Clipboard.setData(ClipboardData(text: info.toClipboardText()));
      if (!mounted) return;
      setState(() {
        _copying = false;
        _copyFailed = false;
        _copyMessage = '应用信息已复制';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _copying = false;
        _copyFailed = true;
        _copyMessage = '复制失败，请重试';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = ref.watch(appInfoProvider);
    final value = info.asData?.value;
    final canCopy =
        value != null && !info.isLoading && !info.hasError && !_copying;
    final theme = Theme.of(context);
    return AlertDialog(
      semanticLabel: '关于 Any2MD',
      constraints: const BoxConstraints(maxWidth: 440),
      scrollable: true,
      title: Row(
        children: [
          Image.asset(
            'assets/branding/any2md_logo.png',
            width: 40,
            height: 40,
            excludeFromSemantics: true,
          ),
          const SizedBox(width: 12),
          const Expanded(child: Text('关于 Any2MD')),
        ],
      ),
      content: SizedBox(
        width: 392,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '本地办公文档转 Markdown 工具',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            info.when(
              skipLoadingOnRefresh: false,
              data: (value) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _InfoRow(label: '应用版本', value: value.displayVersion),
                  _InfoRow(label: '构建号', value: value.displayBuildNumber),
                  _InfoRow(label: '操作系统', value: value.platformLabel),
                ],
              ),
              loading: () => const Text('正在读取版本信息…'),
              error: (error, stackTrace) => Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('暂时无法读取版本信息'),
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: () => ref.invalidate(appInfoProvider),
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('重试'),
                  ),
                ],
              ),
            ),
            if (_copyMessage case final message?) ...[
              const SizedBox(height: 12),
              Semantics(
                liveRegion: true,
                child: Text(
                  message,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: _copyFailed
                        ? theme.colorScheme.error
                        : theme.colorScheme.primary,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      actionsAlignment: MainAxisAlignment.spaceBetween,
      actions: [
        TextButton.icon(
          onPressed: canCopy ? () => _copyInfo(value) : null,
          icon: const Icon(Icons.copy_outlined, size: 18),
          label: const Text('复制信息'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: SelectableText(value, style: theme.textTheme.bodyMedium),
          ),
        ],
      ),
    );
  }
}
