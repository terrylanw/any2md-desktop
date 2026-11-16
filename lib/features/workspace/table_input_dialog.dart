import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'tsv_table_converter.dart';

class TsvTableInput {
  const TsvTableInput({
    required this.text,
    required this.firstRowIsHeader,
    required this.table,
  });

  final String text;
  final bool firstRowIsHeader;
  final TsvTable table;
}

Future<TsvTableInput?> showTsvTableInputDialog(
  BuildContext context, {
  String initialText = '',
  bool firstRowIsHeader = true,
  bool isEditing = false,
}) {
  return showDialog<TsvTableInput>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _TsvTableInputDialog(
      initialText: initialText,
      firstRowIsHeader: firstRowIsHeader,
      isEditing: isEditing,
    ),
  );
}

class _TsvTableInputDialog extends StatefulWidget {
  const _TsvTableInputDialog({
    required this.initialText,
    required this.firstRowIsHeader,
    required this.isEditing,
  });

  final String initialText;
  final bool firstRowIsHeader;
  final bool isEditing;

  @override
  State<_TsvTableInputDialog> createState() => _TsvTableInputDialogState();
}

class _TsvTableInputDialogState extends State<_TsvTableInputDialog> {
  static const _asyncValidationThreshold =
      TsvTableConverter.backgroundThreshold;
  static const _validationDebounce = Duration(milliseconds: 80);

  late final TextEditingController _textController;
  final _previewHorizontalController = ScrollController();
  final _previewVerticalController = ScrollController();
  late bool _firstRowIsHeader;
  late String _sourceText;
  bool _isEditingLargeSource = false;
  TsvTable? _table;
  String? _validatedSource;
  Timer? _validationTimer;
  int _validationRequest = 0;
  bool _isValidating = false;
  bool _validationRunning = false;
  bool _validationPending = false;
  String? _error;
  String? _clipboardMessage;

  @override
  void initState() {
    super.initState();
    _sourceText = widget.initialText;
    _textController = TextEditingController(
      text: widget.initialText.length < _asyncValidationThreshold
          ? widget.initialText
          : '',
    );
    _firstRowIsHeader = widget.firstRowIsHeader;
    if (widget.initialText.length < _asyncValidationThreshold) {
      _validateSource(widget.initialText);
    } else {
      _isValidating = true;
      final request = ++_validationRequest;
      _validationTimer = Timer(_validationDebounce, () {
        _validationTimer = null;
        unawaited(_validateLargeSource(widget.initialText, request));
      });
    }
  }

  @override
  void dispose() {
    _validationTimer?.cancel();
    _textController.dispose();
    _previewHorizontalController.dispose();
    _previewVerticalController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final width = math.min(900.0, math.max(320.0, size.width - 48));
    final height = math.min(700.0, math.max(380.0, size.height - 48));

    return Dialog(
      child: SizedBox(
        width: width,
        height: height,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.isEditing ? '编辑表格源数据' : '粘贴表格',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: _pasteClipboard,
                    icon: const Icon(Icons.content_paste, size: 18),
                    label: const Text('从剪贴板粘贴'),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '按 Tab 分列、按换行分行。支持带引号的 Tab 和单元格内换行。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 10),
              Expanded(flex: 5, child: _buildInput()),
              const SizedBox(height: 10),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('首行为表头'),
                subtitle: const Text('关闭时会生成“列 1、列 2……”表头'),
                value: _firstRowIsHeader,
                onChanged: (value) => setState(() => _firstRowIsHeader = value),
              ),
              _buildStatus(),
              const SizedBox(height: 8),
              SizedBox(
                height: math.min(180.0, height * 0.25),
                child: _buildPreview(),
              ),
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _table == null ? null : _submit,
                    icon: const Icon(Icons.table_view_outlined, size: 18),
                    label: Text(widget.isEditing ? '重新生成' : '生成 Markdown'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatus() {
    final table = _table;
    final errorColor = Theme.of(context).colorScheme.error;
    if (_error == null &&
        table == null &&
        _clipboardMessage == null &&
        !_isValidating) {
      return const SizedBox(height: 20);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_isValidating) const Text('正在解析表格…'),
        if (_error case final error?)
          Text(error, style: TextStyle(color: errorColor)),
        if (table != null)
          Text(
            '识别到 ${table.columnCount} 列、'
            '${table.rows.length - (_firstRowIsHeader ? 1 : 0)} 条数据',
          ),
        if (_clipboardMessage case final message?)
          Text(message, style: TextStyle(color: errorColor)),
      ],
    );
  }

  Widget _buildPreview() {
    final table = _table;
    if (table == null) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Text(
          _clipboardMessage ?? '输入有效 TSV 后将显示前 5 条记录预览。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      );
    }

    final header = _firstRowIsHeader
        ? table.rows.first
        : List<String>.generate(table.columnCount, (index) => '列 ${index + 1}');
    final dataRows = _firstRowIsHeader ? table.rows.skip(1) : table.rows;
    final visibleRows = dataRows.take(5).toList(growable: false);
    if (visibleRows.isEmpty) {
      return const Align(
        alignment: Alignment.centerLeft,
        child: Text('表格仅包含表头。'),
      );
    }

    return Scrollbar(
      key: const ValueKey('tsv-preview-vertical-scrollbar'),
      controller: _previewVerticalController,
      thumbVisibility: true,
      interactive: true,
      scrollbarOrientation: ScrollbarOrientation.right,
      notificationPredicate: (notification) =>
          notification.depth == 1 && notification.metrics.axis == Axis.vertical,
      child: Scrollbar(
        key: const ValueKey('tsv-preview-horizontal-scrollbar'),
        controller: _previewHorizontalController,
        thumbVisibility: true,
        interactive: true,
        scrollbarOrientation: ScrollbarOrientation.bottom,
        notificationPredicate: (notification) =>
            notification.depth == 0 &&
            notification.metrics.axis == Axis.horizontal,
        child: Padding(
          padding: const EdgeInsets.only(right: 16, bottom: 16),
          child: ScrollConfiguration(
            behavior: ScrollConfiguration.of(
              context,
            ).copyWith(scrollbars: false),
            child: SingleChildScrollView(
              key: const ValueKey('tsv-preview-horizontal-scroll-view'),
              controller: _previewHorizontalController,
              primary: false,
              scrollDirection: Axis.horizontal,
              child: SingleChildScrollView(
                key: const ValueKey('tsv-preview-vertical-scroll-view'),
                controller: _previewVerticalController,
                primary: false,
                child: DataTable(
                  horizontalMargin: 10,
                  columnSpacing: 18,
                  columns: [
                    for (final value in header)
                      DataColumn(
                        label: Text(
                          value.isEmpty ? '（空）' : value,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  rows: [
                    for (final row in visibleRows)
                      DataRow(
                        cells: [
                          for (final value in row)
                            DataCell(
                              ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 320,
                                ),
                                child: Text(
                                  value,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildInput() {
    if (_sourceText.length >= _asyncValidationThreshold &&
        !_isEditingLargeSource) {
      final previewLength = math.min(320, _sourceText.length);
      return DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.description_outlined, size: 18),
                  const SizedBox(width: 8),
                  const Expanded(child: Text('大型表格文本已加载')),
                  TextButton.icon(
                    onPressed: _editLargeSource,
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: const Text('编辑原文'),
                  ),
                  IconButton(
                    onPressed: _clearSource,
                    tooltip: '清空内容',
                    icon: const Icon(Icons.delete_outline),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: SingleChildScrollView(
                  child: Text(
                    '${_sourceText.substring(0, previewLength)}'
                    '${previewLength < _sourceText.length ? '…' : ''}',
                    maxLines: 8,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: TextField(
            controller: _textController,
            autofocus: true,
            expands: true,
            minLines: null,
            maxLines: null,
            textAlignVertical: TextAlignVertical.top,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: '在此粘贴或输入制表符分隔的内容…',
              alignLabelWithHint: true,
            ),
            onChanged: (_) => _onTextChanged(),
          ),
        ),
        if (_isEditingLargeSource)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: _collapseLargeSource,
              icon: const Icon(Icons.unfold_less, size: 18),
              label: const Text('收起原文'),
            ),
          ),
      ],
    );
  }

  void _onTextChanged() {
    _acceptSource(
      _textController.text,
      collapseLargeInput: !_isEditingLargeSource,
    );
  }

  void _acceptSource(String source, {bool collapseLargeInput = true}) {
    _clipboardMessage = null;
    final shouldCollapse =
        collapseLargeInput && source.length >= _asyncValidationThreshold;
    if (shouldCollapse) _textController.value = TextEditingValue.empty;
    if (source == _validatedSource) {
      setState(() {
        _sourceText = source;
        if (shouldCollapse) _isEditingLargeSource = false;
        if (source.length < _asyncValidationThreshold) {
          _isEditingLargeSource = false;
        }
      });
      return;
    }
    _validationTimer?.cancel();
    _validationTimer = null;
    _validationPending = false;
    final request = ++_validationRequest;
    if (source.length < _asyncValidationThreshold) {
      setState(() {
        _sourceText = source;
        _isEditingLargeSource = false;
        _validateSource(source);
      });
      return;
    }

    setState(() {
      _sourceText = source;
      if (shouldCollapse) _isEditingLargeSource = false;
      _validatedSource = null;
      _table = null;
      _error = null;
      _clipboardMessage = null;
      _isValidating = true;
    });
    _validationTimer = Timer(_validationDebounce, () {
      _validationTimer = null;
      unawaited(_validateLargeSource(source, request));
    });
  }

  Future<void> _validateLargeSource(String source, int request) async {
    if (_validationRunning) {
      _validationPending = true;
      return;
    }
    _validationRunning = true;
    TsvTable? table;
    String? errorMessage;
    try {
      table = await TsvTableConverter.parseAsync(source);
    } on TsvTableFormatException catch (error) {
      errorMessage = error.toString();
    } on Object catch (error) {
      errorMessage = '解析表格失败：$error';
    } finally {
      _validationRunning = false;
    }
    if (!mounted) return;
    if (request == _validationRequest && _sourceText == source) {
      setState(() {
        _validatedSource = source;
        _table = table;
        _error = errorMessage;
        _isValidating = false;
      });
    }
    if (_validationPending) {
      _validationPending = false;
      unawaited(_validateLargeSource(_sourceText, _validationRequest));
    }
  }

  void _validateSource(String source) {
    if (source == _validatedSource) return;
    _validatedSource = source;
    _clipboardMessage = null;
    _isValidating = false;
    try {
      _table = TsvTableConverter.parse(source);
      _error = null;
    } on TsvTableFormatException catch (error) {
      _table = null;
      _error = error.toString();
    }
  }

  Future<void> _pasteClipboard() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (!mounted) return;
      final text = data?.text;
      if (text == null) {
        setState(() {
          _clipboardMessage = '剪贴板没有可读取的文本；也可以直接在输入框中粘贴。';
        });
        return;
      }
      if (text.length < _asyncValidationThreshold) {
        _textController.value = TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: text.length),
        );
      }
      _acceptSource(text);
    } on Object {
      if (!mounted) return;
      setState(() {
        _clipboardMessage = '读取剪贴板失败；输入框中的内容已保留。';
      });
    }
  }

  void _submit() {
    if (_table == null) return;
    Navigator.pop(
      context,
      TsvTableInput(
        text: _sourceText,
        firstRowIsHeader: _firstRowIsHeader,
        table: _table!,
      ),
    );
  }

  void _editLargeSource() {
    final text = _sourceText;
    setState(() {
      _isEditingLargeSource = true;
      _textController.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    });
  }

  void _collapseLargeSource() {
    _textController.value = TextEditingValue.empty;
    setState(() => _isEditingLargeSource = false);
  }

  void _clearSource() {
    _textController.clear();
    _acceptSource('');
  }
}
