import SwiftData
import SwiftUI

enum FillSort: String, CaseIterable, Identifiable {
    case dateFilled = "Date filled"
    case drug = "Drug"
    case copay = "Copay"
    var id: String { rawValue }
}

struct FillFilter: Equatable {
    var medicationKey: String?
    var year: Int?
    var source: DataSource?

    var isActive: Bool { medicationKey != nil || year != nil || source != nil }
}

/// Pure filtering/sorting logic, separated from the view so it is easy to reason about.
enum FillListLogic {
    static func apply(_ fills: [Fill], search: String, filter: FillFilter, sort: FillSort) -> [Fill] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        let queryDigits = query.filter(\.isASCIIDigit)
        let filtered = fills.filter { fill in
            if let key = filter.medicationKey, fill.medication?.matchKey != key { return false }
            if let year = filter.year, LabelFormat.year(of: fill.sortDate) != year { return false }
            if let source = filter.source, fill.source != source { return false }
            guard !query.isEmpty else { return true }
            if fill.displayName.lowercased().contains(query) { return true }
            if let brands = fill.commonBrands?.lowercased(), brands.contains(query) { return true }
            if !queryDigits.isEmpty {
                if let ndc = fill.ndcNormalized, ndc.contains(queryDigits) { return true }
                if let rx = fill.rxNumber, rx.contains(queryDigits) { return true }
            }
            if let ndc = fill.ndc, ndc.contains(query) { return true }
            return false
        }
        switch sort {
        case .dateFilled:
            return filtered.sorted { $0.sortDate > $1.sortDate }
        case .drug:
            return filtered.sorted {
                let c = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
                return c == .orderedSame ? $0.sortDate > $1.sortDate : c == .orderedAscending
            }
        case .copay:
            return filtered.sorted { ($0.amountDue ?? -1) > ($1.amountDue ?? -1) }
        }
    }
}

struct FillsListView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppState.self) private var appState
    @Query(sort: \Fill.createdAt, order: .reverse) private var fills: [Fill]
    @Query(sort: \Medication.displayName) private var medications: [Medication]

    @State private var searchText = ""
    @State private var filter = FillFilter()
    @State private var sort: FillSort = .dateFilled
    @State private var showingManualEntry = false
    @State private var pendingDelete: Fill?
    @State private var errorMessage: String?

    private var visibleFills: [Fill] {
        FillListLogic.apply(fills, search: searchText, filter: filter, sort: sort)
    }

    private var years: [Int] {
        Array(Set(fills.map { LabelFormat.year(of: $0.sortDate) })).sorted(by: >)
    }

    var body: some View {
        @Bindable var appState = appState
        NavigationStack(path: $appState.fillsPath) {
            ScrollViewReader { proxy in
                List {
                    ForEach(visibleFills) { fill in
                        NavigationLink(value: fill) {
                            FillRow(fill: fill)
                        }
                        .id(fill.id)
                        .listRowBackground(appState.highlightedFillID == fill.id ? Color.accentColor.opacity(0.18) : nil)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingDelete = fill
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .overlay { emptyState }
                .onChange(of: appState.highlightedFillID, initial: true) { _, id in
                    guard let id else { return }
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                    Task {
                        try? await Task.sleep(for: .seconds(2.5))
                        withAnimation(.easeOut(duration: 0.6)) {
                            if appState.highlightedFillID == id { appState.highlightedFillID = nil }
                        }
                    }
                }
            }
            .navigationTitle("Fills")
            .navigationDestination(for: Fill.self) { fill in
                FillDetailView(fill: fill)
            }
            .searchable(text: $searchText, prompt: "Drug, NDC or Rx number")
            .toolbar { toolbarContent }
            .sheet(isPresented: $showingManualEntry) {
                NavigationStack {
                    FillEditorView(title: "Add Manually", initialDraft: FillDraft(), purpose: .create(source: .manual, ocr: nil)) { result in
                        showingManualEntry = false
                        handle(result)
                    }
                }
            }
            .confirmationDialog(
                "Delete this fill?",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible,
                presenting: pendingDelete
            ) { fill in
                Button("Delete \(fill.displayName)", role: .destructive) { delete(fill) }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            } message: { fill in
                Text("\(DedupeService.describe(fill)) will be permanently removed.")
            }
            .alert("Couldn't delete", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if fills.isEmpty {
            ContentUnavailableView {
                Label("No Fills Yet", systemImage: "pills")
            } description: {
                Text("Scan a CVS label from the Capture tab, or add a fill manually.")
            } actions: {
                Button("Add Manually") { showingManualEntry = true }
                    .buttonStyle(.borderedProminent)
            }
        } else if visibleFills.isEmpty {
            if searchText.isEmpty {
                ContentUnavailableView("No Matching Fills", systemImage: "line.3.horizontal.decrease.circle",
                                       description: Text("Try clearing the filters."))
            } else {
                ContentUnavailableView.search(text: searchText)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarLeading) {
            Menu {
                Picker("Medication", selection: $filter.medicationKey) {
                    Text("All medications").tag(String?.none)
                    ForEach(medications) { med in
                        Text(med.displayName).tag(String?.some(med.matchKey))
                    }
                }
                Picker("Year", selection: $filter.year) {
                    Text("All years").tag(Int?.none)
                    ForEach(years, id: \.self) { year in
                        Text(String(year)).tag(Int?.some(year))
                    }
                }
                Picker("Source", selection: $filter.source) {
                    Text("All sources").tag(DataSource?.none)
                    ForEach(DataSource.allCases) { source in
                        Label(source.label, systemImage: source.systemImage).tag(DataSource?.some(source))
                    }
                }
                if filter.isActive {
                    Button("Clear Filters", role: .destructive) { filter = FillFilter() }
                }
            } label: {
                Image(systemName: filter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
            .accessibilityLabel(filter.isActive ? "Filters, active" : "Filters")

            Menu {
                Picker("Sort by", selection: $sort) {
                    ForEach(FillSort.allCases) { Text($0.rawValue).tag($0) }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            .accessibilityLabel("Sort, currently by \(sort.rawValue)")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showingManualEntry = true
            } label: {
                Label("Add Manually", systemImage: "plus")
            }
        }
    }

    private func handle(_ result: EditorResult) {
        switch result {
        case .saved(let fill): appState.showSaved(fill)
        case .viewExisting(let fill): appState.open(fill)
        case .cancelled: break
        }
    }

    private func delete(_ fill: Fill) {
        pendingDelete = nil
        do {
            try FillRepository(context: context).delete(fill)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct FillRow: View {
    let fill: Fill

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(fill.displayName.isEmpty ? "Untitled fill" : fill.displayName)
                    .font(.headline)
                    .lineLimit(2)
                Spacer(minLength: 8)
                SourceBadge(source: fill.source, edited: fill.wasEditedAfterScan, compact: true)
            }
            HStack {
                Text(fill.dateFilled.map { LabelFormat.formatMedium($0) } ?? "No fill date")
                if let ndc = fill.ndc {
                    Text("·")
                    Text("NDC \(ndc)").monospacedDigit()
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            HStack {
                if let q = fill.quantityText { Text("Qty \(q)") }
                if let d = fill.daysSupply { Text("· \(d) days") }
                Spacer()
                Text("Retail \(LabelFormat.formatMoney(fill.retailPrice))")
                    .foregroundStyle(.secondary)
                Text("Copay \(LabelFormat.formatMoney(fill.amountDue))")
                    .fontWeight(.semibold)
            }
            .font(.caption)
            .monospacedDigit()
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

#Preview("Fills") {
    FillsListView()
        .environment(AppState())
        .modelContainer(PersistenceController.preview)
}

#Preview("Empty") {
    FillsListView()
        .environment(AppState())
        .modelContainer(for: [Fill.self, Medication.self], inMemory: true)
}
