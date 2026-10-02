import '../domain/sample_item.dart';
import '../domain/sample_repository.dart';

class InMemorySampleRepository implements SampleRepository {
  static const List<SampleItem> _items = [
    SampleItem(
      id: 'first',
      title: 'First item',
      description: 'A small example of repository-backed content.',
    ),
    SampleItem(
      id: 'second',
      title: 'Second item',
      description: 'This detail is resolved from a stable item ID.',
    ),
    SampleItem(
      id: 'third',
      title: 'Third item',
      description: 'Replace the in-memory source when real data is needed.',
    ),
  ];

  @override
  Future<List<SampleItem>> fetchItems() async => List.unmodifiable(_items);

  @override
  Future<SampleItem?> fetchItem(String id) async {
    for (final item in _items) {
      if (item.id == id) return item;
    }
    return null;
  }
}
