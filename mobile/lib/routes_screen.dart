import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'local_store.dart';
import 'route_models.dart';
import 'route_editor_screen.dart';
import 'gpx_service.dart';
import 'ui_helpers.dart';

class RoutesScreen extends StatefulWidget {
  const RoutesScreen({super.key, required this.store, this.showTiles = true});
  final LocalStore store;
  final bool showTiles;
  @override
  State<RoutesScreen> createState() => _RoutesScreenState();
}

class _RoutesScreenState extends State<RoutesScreen> {
  late Future<List<SavedRoute>> data = widget.store.routes();
  SavedRoute? editing;
  bool importing = false;
  void refresh() {
    if (mounted) {
      setState(() {
        data = widget.store.routes();
      });
    }
  }

  Future<void> import() async {
    setState(() => importing = true);
    try {
      final file = await FilePicker.pickFile(type: FileType.any);
      if (file == null) return;
      final size = await file.length();
      if (size != null && size > GpxService.maxBytes) {
        throw const FormatException('GPX exceeds 5 MB');
      }
      final bytes = await file.readAsBytes();
      if (bytes.length > GpxService.maxBytes) {
        throw const FormatException('GPX exceeds 5 MB');
      }
      final route = GpxService.parse(utf8.decode(bytes));
      await widget.store.saveRoute(route);
      if (mounted) {
        refresh();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('GPX imported as a local route')),
        );
      }
    } catch (e) {
      if (mounted) await showError(context, e);
    } finally {
      if (mounted) setState(() => importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (editing != null) {
      return RouteEditorScreen(
        key: ValueKey(editing),
        route: editing!,
        showTiles: widget.showTiles,
        close: () => setState(() => editing = null),
        save: (route) async {
          await widget.store.saveRoute(route);
          if (mounted) {
            setState(() => editing = null);
            refresh();
          }
        },
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: importing
                      ? null
                      : () => setState(
                          () => editing = SavedRoute(null, '', 'draft', [], []),
                        ),
                  icon: const Icon(Icons.add),
                  label: const Text('Create route'),
                ),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: importing ? null : import,
                icon: const Icon(Icons.upload_file),
                label: const Text('Import GPX'),
              ),
            ],
          ),
        ),
        Expanded(
          child: FutureBuilder<List<SavedRoute>>(
            future: data,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Routes unavailable: ${snapshot.error}'),
                      TextButton(
                        onPressed: refresh,
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                );
              }
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.data!.isEmpty) {
                return const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Save stops for your next ride, or import a GPX track.\nDraft routes use straight lines.',
                    ),
                  ),
                );
              }
              return ListView(
                children: snapshot.data!
                    .map(
                      (route) => Card(
                        margin: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 5,
                        ),
                        child: ListTile(
                          title: Text(route.name),
                          subtitle: Text(
                            '${route.kind == 'imported' ? 'Imported GPX' : 'Draft — straight lines'} • ${route.geometry.length} points',
                          ),
                          onTap: () => setState(() => editing = route),
                          trailing: IconButton(
                            tooltip: 'Delete route',
                            onPressed: () async {
                              if (!await confirmDelete(context, route.name)) {
                                return;
                              }
                              try {
                                await widget.store.deleteRoute(route.id!);
                                if (mounted) refresh();
                              } catch (e) {
                                if (context.mounted) {
                                  await showError(context, e);
                                }
                              }
                            },
                            icon: const Icon(Icons.delete_outline),
                          ),
                        ),
                      ),
                    )
                    .toList(),
              );
            },
          ),
        ),
      ],
    );
  }
}
