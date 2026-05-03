//
//  RunHistoryViewModel.swift
//  Harness
//

import Foundation
import Observation

@Observable
@MainActor
final class RunHistoryViewModel {

    var runs: [RunRecordSnapshot] = []
    var isLoading = false

    private let store: any RunHistoryStoring

    init(store: any RunHistoryStoring) {
        self.store = store
    }

    func reload() async {
        isLoading = true
        defer { isLoading = false }
        runs = (try? await store.fetchRecent(limit: 100)) ?? []
    }

    func delete(id: UUID) async {
        try? await store.delete(id: id)
        await reload()
    }
}
