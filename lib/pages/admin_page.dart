import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/admin_data_files.dart';

/// Desktop admin screen to inspect and delete local HKO archive data files.
class AdminPage extends StatefulWidget {
  const AdminPage({super.key});

  @override
  State<AdminPage> createState() => _AdminPageState();
}

class _AdminPageState extends State<AdminPage>
    with AutomaticKeepAliveClientMixin {
  final _timeFmt = DateFormat('yyyy-MM-dd HH:mm');

  List<AdminDataFile> _files = [];
  final Set<String> _selected = {};
  bool _loading = true;
  bool _deleting = false;
  String? _error;

  String _fmtBytes(int n) {
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    return '${(n / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    if (!adminDataFilesSupported) {
      setState(() {
        _loading = false;
        _files = [];
        _selected.clear();
        _error = null;
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final files = await listAdminDataFiles();
      if (!mounted) return;
      setState(() {
        _files = files;
        _selected.removeWhere((p) => files.every((f) => f.path != p));
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _toggleAll(bool? select) {
    setState(() {
      if (select == true) {
        _selected
          ..clear()
          ..addAll(_files.map((f) => f.path));
      } else {
        _selected.clear();
      }
    });
  }

  Future<void> _deleteSelected() async {
    if (_selected.isEmpty || _deleting) return;
    final count = _selected.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete files?'),
        content: Text(
          'Permanently delete $count selected file${count == 1 ? '' : 's'} '
          'from the local HKO archive?\n\nThis cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _deleting = true);
    try {
      await deleteAdminDataFiles(_selected.toList());
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Deleted $count file${count == 1 ? '' : 's'}')),
      );
      await _reload();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Delete failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final scheme = Theme.of(context).colorScheme;

    if (!adminDataFilesSupported) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Admin file management is available on the Windows desktop app.\n'
            'GitHub Pages data is updated via Actions, not from the browser.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13),
          ),
        ),
      );
    }

    final allSelected =
        _files.isNotEmpty && _selected.length == _files.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 6, 4),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Local HKO archive',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: scheme.primary,
                      ),
                    ),
                    Text(
                      adminDataRootPath(),
                      style: TextStyle(
                        fontSize: 10,
                        color: scheme.onSurfaceVariant,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      '${_files.length} files · ${_selected.length} selected',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              Checkbox(
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                value: allSelected
                    ? true
                    : (_selected.isEmpty ? false : null),
                tristate: true,
                onChanged: _files.isEmpty ? null : _toggleAll,
              ),
              const Text(
                'All',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 4),
              FilledButton.tonal(
                onPressed: (_selected.isEmpty || _deleting) ? null : _deleteSelected,
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  minimumSize: const Size(0, 28),
                  textStyle: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                child: Text(_deleting ? 'Deleting…' : 'Delete'),
              ),
              IconButton(
                tooltip: 'Refresh file list',
                visualDensity: VisualDensity.compact,
                onPressed: (_loading || _deleting) ? null : _reload,
                icon: const Icon(Icons.refresh, size: 18),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(child: _buildBody(scheme)),
      ],
    );
  }

  Widget _buildBody(ColorScheme scheme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _reload,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }
    if (_files.isEmpty) {
      return const Center(child: Text('No data files found'));
    }

    String? lastCategory;
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
      itemCount: _files.length,
      itemBuilder: (context, index) {
        final file = _files[index];
        final showHeader = file.category != lastCategory;
        lastCategory = file.category;
        final selected = _selected.contains(file.path);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (showHeader)
              Padding(
                padding: EdgeInsets.fromLTRB(4, index == 0 ? 4 : 10, 4, 4),
                child: Text(
                  file.category.toUpperCase(),
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: scheme.primary,
                  ),
                ),
              ),
            Material(
              color: selected
                  ? scheme.primaryContainer.withValues(alpha: 0.35)
                  : Colors.white,
              child: InkWell(
                onTap: () {
                  setState(() {
                    if (selected) {
                      _selected.remove(file.path);
                    } else {
                      _selected.add(file.path);
                    }
                  });
                },
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(2, 2, 8, 2),
                  child: Row(
                    children: [
                      Checkbox(
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        value: selected,
                        onChanged: (v) {
                          setState(() {
                            if (v == true) {
                              _selected.add(file.path);
                            } else {
                              _selected.remove(file.path);
                            }
                          });
                        },
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              file.relativePath,
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              '${_fmtBytes(file.bytes)} · '
                              '${_timeFmt.format(file.modified)}',
                              style: TextStyle(
                                fontSize: 10,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
