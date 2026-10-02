import 'sample_item.dart';

abstract interface class SampleRepository {
  Future<List<SampleItem>> fetchItems();

  Future<SampleItem?> fetchItem(String id);
}
