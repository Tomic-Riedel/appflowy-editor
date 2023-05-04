import 'dart:async';
import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';

import 'package:appflowy_editor/src/history/undo_manager.dart';

class ApplyOptions {
  /// This flag indicates that
  /// whether the transaction should be recorded into
  /// the undo stack
  final bool recordUndo;
  final bool recordRedo;
  const ApplyOptions({
    this.recordUndo = true,
    this.recordRedo = false,
  });
}

// deprecated
enum CursorUpdateReason {
  uiEvent,
  others,
}

enum SelectionUpdateReason {
  uiEvent, // like mouse click, keyboard event
  transaction, // like insert, delete, format
}

/// The state of the editor.
///
/// The state includes:
/// - The document to render
/// - The state of the selection
///
/// [EditorState] also includes the services of the editor:
/// - Selection service
/// - Scroll service
/// - Keyboard service
/// - Input service
/// - Toolbar service
///
/// In consideration of collaborative editing,
/// all the mutations should be applied through [Transaction].
///
/// Mutating the document with document's API is not recommended.
class EditorState {
  final Document document;

  final ValueNotifier<Selection?> selectionNotifier =
      ValueNotifier<Selection?>(null);
  Selection? get selection => selectionNotifier.value;
  set selection(Selection? value) {
    selectionNotifier.value = value;
  }

  SelectionUpdateReason _selectionUpdateReason = SelectionUpdateReason.uiEvent;
  SelectionUpdateReason get selectionUpdateReason => _selectionUpdateReason;

  // Service reference.
  final service = FlowyService();

  AppFlowySelectionService get selectionService => service.selectionService;
  // AppFlowyRenderPluginService get renderer => service.renderPluginService;
  BlockComponentRendererService get renderer => service.rendererService;
  set renderer(BlockComponentRendererService value) {
    service.rendererService = value;
  }

  List<CharacterShortcutEvent> characterShortcutEvents = [];

  /// Configures log output parameters,
  /// such as log level and log output callbacks,
  /// with this variable.
  LogConfiguration get logConfiguration => LogConfiguration();

  /// Stores the selection menu items.
  List<SelectionMenuItem> selectionMenuItems = [];

  /// Stores the toolbar items.
  List<ToolbarItem> toolbarItems = [];

  /// Operation stream.
  Stream<Transaction> get transactionStream => _observer.stream;
  final StreamController<Transaction> _observer = StreamController.broadcast();

  late ThemeData themeData;
  late EditorStyle editorStyle;

  final UndoManager undoManager = UndoManager();
  Selection? _cursorSelection;

  // TODO: only for testing.
  bool disableSealTimer = false;
  bool disableRules = false;

  bool editable = true;

  Transaction get transaction {
    final transaction = Transaction(document: document);
    transaction.beforeSelection = selection;
    return transaction;
  }

  Selection? get cursorSelection {
    return _cursorSelection;
  }

  RenderBox? get renderBox {
    final renderObject =
        service.scrollServiceKey.currentContext?.findRenderObject();
    if (renderObject != null && renderObject is RenderBox) {
      return renderObject;
    }
    return null;
  }

  Future<void> updateSelectionWithReason(
    Selection? selection, {
    SelectionUpdateReason reason = SelectionUpdateReason.transaction,
  }) async {
    final completer = Completer<void>();

    if (reason == SelectionUpdateReason.uiEvent) {
      WidgetsBinding.instance.addPostFrameCallback(
        (timeStamp) => completer.complete(),
      );
    }

    // broadcast to other users here
    _selectionUpdateReason = reason;
    this.selection = selection;

    return completer.future;
  }

  Future<void> updateCursorSelection(
    Selection? cursorSelection, [
    CursorUpdateReason reason = CursorUpdateReason.others,
  ]) {
    final completer = Completer<void>();

    // broadcast to other users here
    if (reason != CursorUpdateReason.uiEvent) {
      service.selectionService.updateSelection(cursorSelection);
    }
    _cursorSelection = cursorSelection;
    selection = cursorSelection;
    WidgetsBinding.instance.addPostFrameCallback((timeStamp) {
      completer.complete();
    });
    return completer.future;
  }

  Timer? _debouncedSealHistoryItemTimer;

  EditorState({
    required this.document,
  }) {
    undoManager.state = this;
  }

  factory EditorState.empty() {
    return EditorState(document: Document.empty());
  }

  /// Apply the transaction to the state.
  ///
  /// The options can be used to determine whether the editor
  /// should record the transaction in undo/redo stack.
  ///
  /// The maximumRuleApplyLoop is used to prevent infinite loop.
  ///
  /// The withUpdateSelection is used to determine whether the editor
  /// should update the selection after applying the transaction.
  Future<void> apply(
    Transaction transaction, {
    bool isRemote = false,
    ApplyOptions options = const ApplyOptions(recordUndo: true),
    bool withUpdateSelection = true,
  }) async {
    if (!editable) {
      return;
    }

    final completer = Completer<void>();

    for (final operation in transaction.operations) {
      Log.editor.debug('apply op: ${operation.toJson()}');
      _applyOperation(operation);
    }

    // broadcast to other users here
    _observer.add(transaction);

    _recordRedoOrUndo(options, transaction);

    if (withUpdateSelection) {
      _selectionUpdateReason = SelectionUpdateReason.transaction;
      selection = transaction.afterSelection;
      // if the selection is not changed, we still need to notify the listeners.
      selectionNotifier.notifyListeners();
    }

    // TODO: execute this line after the UI has been updated.
    {
      completer.complete();
    }

    return completer.future;
  }

  /// get nodes in selection
  ///
  /// if selection is backward, return nodes in order
  /// if selection is forward, return nodes in reverse order
  ///
  List<Node> getNodesInSelection(Selection selection) {
    // Normalize the selection.
    final normalized = selection.normalized;

    // Get the start and end nodes.
    final startNode = document.nodeAtPath(normalized.start.path);
    final endNode = document.nodeAtPath(normalized.end.path);

    // If we have both nodes, we can find the nodes in the selection.
    if (startNode != null && endNode != null) {
      final nodes = NodeIterator(
        document: document,
        startNode: startNode,
        endNode: endNode,
      ).toList();
      return selection.isForward ? nodes.reversed.toList() : nodes;
    }

    // If we don't have both nodes, we can't find the nodes in the selection.
    return [];
  }

  Node? getNodeAtPath(Path path) {
    return document.nodeAtPath(path);
  }

  void _recordRedoOrUndo(ApplyOptions options, Transaction transaction) {
    if (options.recordUndo) {
      final undoItem = undoManager.getUndoHistoryItem();
      undoItem.addAll(transaction.operations);
      if (undoItem.beforeSelection == null &&
          transaction.beforeSelection != null) {
        undoItem.beforeSelection = transaction.beforeSelection;
      }
      undoItem.afterSelection = transaction.afterSelection;
      _debouncedSealHistoryItem();
    } else if (options.recordRedo) {
      final redoItem = HistoryItem();
      redoItem.addAll(transaction.operations);
      redoItem.beforeSelection = transaction.beforeSelection;
      redoItem.afterSelection = transaction.afterSelection;
      undoManager.redoStack.push(redoItem);
    }
  }

  void _debouncedSealHistoryItem() {
    if (disableSealTimer) {
      return;
    }
    _debouncedSealHistoryItemTimer?.cancel();
    _debouncedSealHistoryItemTimer =
        Timer(const Duration(milliseconds: 1000), () {
      if (undoManager.undoStack.isNonEmpty) {
        Log.editor.debug('Seal history item');
        final last = undoManager.undoStack.last;
        last.seal();
      }
    });
  }

  void _applyOperation(Operation op) {
    if (op is InsertOperation) {
      document.insert(op.path, op.nodes);
    } else if (op is UpdateOperation) {
      document.update(op.path, op.attributes);
    } else if (op is DeleteOperation) {
      document.delete(op.path, op.nodes.length);
    } else if (op is UpdateTextOperation) {
      document.updateText(op.path, op.delta);
    }
  }

  void _applyRules(int maximumRuleApplyLoop) {
    // Set a maximum count to prevent a dead loop.
    if (maximumRuleApplyLoop >= 5 || disableRules) {
      return;
    }

    // Rules
    _insureLastNodeEditable(transaction);

    if (transaction.operations.isNotEmpty) {
      apply(
        transaction,
        withUpdateSelection: false,
      );
    }
  }

  void _insureLastNodeEditable(Transaction tr) {
    if (document.root.children.isEmpty ||
        document.root.children.last.id != 'text') {
      tr.insertNode([document.root.children.length], TextNode.empty());
    }
  }
}
