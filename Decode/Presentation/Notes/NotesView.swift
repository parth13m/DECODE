import SwiftUI

/// Displays all saved explanation notes in a two-pane layout:
/// a card-based list on the left with time-grouped sections,
/// and a reading area on the right.
struct NotesView: View {

    @Environment(AppDependencies.self) private var dependencies
    @State private var notes: [Note] = []
    @State private var selectedNote: Note?
    @State private var searchText = ""
    @State private var isLoading = true

    // Decode palette
    private let warmBackground = Color(red: 0.98, green: 0.97, blue: 0.95)
    private let accentOrange = Color(red: 0.91, green: 0.47, blue: 0.18)
    private let cardBorder = Color(red: 0.91, green: 0.90, blue: 0.88)
    private let textPrimary = Color(red: 0.12, green: 0.12, blue: 0.12)
    private let textSecondary = Color(red: 0.50, green: 0.49, blue: 0.47)

    private var filteredNotes: [Note] {
        if searchText.isEmpty { return notes }
        let query = searchText.lowercased()
        return notes.filter {
            $0.title.lowercased().contains(query)
                || ($0.language?.lowercased().contains(query) ?? false)
                || ($0.filePath?.lowercased().contains(query) ?? false)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            notesListPanel
            Divider()
                .overlay(cardBorder)
            readingArea
        }
        .background(warmBackground)
        .task {
            await loadNotes()
        }
    }

    // MARK: - Notes List Panel

    private var notesListPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 12) {
                Text("Notes")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(textPrimary)

                // Search
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(textSecondary)
                        .font(.system(size: 12))
                    TextField("Search notes...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundStyle(textPrimary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(cardBorder, lineWidth: 1)
                        )
                )
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 16)

            // List content
            if isLoading {
                Spacer()
                HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                Spacer()
            } else if filteredNotes.isEmpty {
                Spacer()
                emptyListState
                Spacer()
            } else {
                groupedNotesList
            }
        }
        .frame(width: 300)
    }

    // MARK: - Grouped Notes

    private var groupedNotesList: some View {
        let grouped = groupNotesByTime(filteredNotes)

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(grouped, id: \.label) { group in
                    Text(group.label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(textSecondary)
                        .textCase(.uppercase)
                        .tracking(0.5)
                        .padding(.horizontal, 16)
                        .padding(.top, group.label == grouped.first?.label ? 0 : 20)
                        .padding(.bottom, 8)

                    ForEach(group.notes) { note in
                        noteCard(note)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 6)
                    }
                }
            }
            .padding(.bottom, 16)
        }
    }

    private func noteCard(_ note: Note) -> some View {
        let isSelected = selectedNote?.id == note.id

        return Button {
            selectedNote = note
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(note.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isSelected ? .white : textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 6) {
                    if let language = note.language {
                        Text(language)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(isSelected ? .white.opacity(0.85) : accentOrange)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(isSelected ? Color.white.opacity(0.2) : accentOrange.opacity(0.12))
                            )
                    }

                    if let mode = note.mode {
                        Text(mode.capitalized)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(isSelected ? .white.opacity(0.7) : textSecondary)
                    }

                    Spacer()

                    Text(note.createdAt, style: .relative)
                        .font(.system(size: 10))
                        .foregroundStyle(isSelected ? .white.opacity(0.7) : textSecondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? accentOrange : Color.white)
                    .shadow(color: .black.opacity(isSelected ? 0.08 : 0.03), radius: isSelected ? 4 : 2, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? accentOrange : cardBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                Task { await deleteNote(note) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Reading Area

    private var readingArea: some View {
        Group {
            if let note = selectedNote {
                NoteDetailView(note: note)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "bookmark")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(textSecondary.opacity(0.4))
                    Text("Select a note to read")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(warmBackground)
            }
        }
    }

    // MARK: - Empty List

    private var emptyListState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bookmark")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(textSecondary.opacity(0.4))
            Text(searchText.isEmpty ? "No notes yet" : "No matching notes")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(textSecondary)
            if searchText.isEmpty {
                Text("Save explanations using the\nNote button in the popup.")
                    .font(.system(size: 11))
                    .foregroundStyle(textSecondary.opacity(0.6))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Time Grouping

    private struct NoteGroup {
        let label: String
        let notes: [Note]
    }

    private func groupNotesByTime(_ notes: [Note]) -> [NoteGroup] {
        let calendar = Calendar.current
        let now = Date()

        var today: [Note] = []
        var yesterday: [Note] = []
        var thisWeek: [Note] = []
        var earlier: [Note] = []

        for note in notes {
            if calendar.isDateInToday(note.createdAt) {
                today.append(note)
            } else if calendar.isDateInYesterday(note.createdAt) {
                yesterday.append(note)
            } else if let weekAgo = calendar.date(byAdding: .day, value: -7, to: now),
                      note.createdAt > weekAgo {
                thisWeek.append(note)
            } else {
                earlier.append(note)
            }
        }

        var groups: [NoteGroup] = []
        if !today.isEmpty { groups.append(NoteGroup(label: "Today", notes: today)) }
        if !yesterday.isEmpty { groups.append(NoteGroup(label: "Yesterday", notes: yesterday)) }
        if !thisWeek.isEmpty { groups.append(NoteGroup(label: "This Week", notes: thisWeek)) }
        if !earlier.isEmpty { groups.append(NoteGroup(label: "Earlier", notes: earlier)) }
        return groups
    }

    // MARK: - Actions

    private func loadNotes() async {
        guard let service = dependencies.noteService else {
            isLoading = false
            return
        }
        do {
            notes = try await service.allNotes()
        } catch {
            #if DEBUG
            print("[DEBUG NOTES] load failed: \(error.localizedDescription)")
            #endif
        }
        isLoading = false
    }

    private func deleteNote(_ note: Note) async {
        guard let service = dependencies.noteService else { return }
        do {
            try await service.deleteNote(note)
            notes.removeAll { $0.id == note.id }
            if selectedNote?.id == note.id {
                selectedNote = nil
            }
        } catch {
            #if DEBUG
            print("[DEBUG NOTES] delete failed: \(error.localizedDescription)")
            #endif
        }
    }
}
