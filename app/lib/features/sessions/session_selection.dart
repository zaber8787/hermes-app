/// BULK-HIDE (plan B4): the pure selection model behind the sessions page.
/// Membership is id-keyed ONLY — sorting, refetched Session objects and
/// filter changes must never shift a selection; a row is removed from the
/// selection only when a COMPLETE list proves the id is gone.
class SessionSelection {
  bool selecting = false;
  final Set<String> selectedIds = {};

  /// Enter (stays entered: union). Optional initial ids come from the row
  /// whose long-press triggered the mode.
  void enter([Iterable<String> withIds = const []]) {
    selecting = true;
    selectedIds.addAll(withIds);
  }

  /// Cancel: clears ids AND the failure view is dropped by the owner.
  void exit() {
    selecting = false;
    selectedIds.clear();
  }

  /// Clear ids without leaving the mode.
  void clearIds() => selectedIds.clear();

  void toggle(String id) {
    if (!selectedIds.remove(id)) selectedIds.add(id);
  }

  /// "Select all in the CURRENT list": union with every id passing the
  /// active filters (the fetched rows, not the mounted widgets).
  void selectAll(Iterable<String> filteredIds) =>
      selectedIds.addAll(filteredIds);

  /// How many selected ids are outside the currently visible rows.
  int outsideCount(Iterable<String> visibleIds) {
    final vis = visibleIds.toSet();
    return selectedIds.where((id) => !vis.contains(id)).length;
  }

  /// A successful COMPLETE list keeps the intersection; ids that really
  /// disappeared leave the selection (and are reported by the caller).
  /// Returns the removed ids for the "no longer exist" notice.
  Set<String> retainExisting(Iterable<String> presentIds) {
    final present = presentIds.toSet();
    final removed = selectedIds.where((id) => !present.contains(id)).toSet();
    selectedIds.removeAll(removed);
    return removed;
  }
}
