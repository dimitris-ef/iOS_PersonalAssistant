import AssistantDomain
import SwiftUI

/// Create or edit a task.
///
/// A plain `Form`, because this is exactly the kind of screen the system
/// controls already do well. The only judgement here is the timing picker,
/// which has to express the domain's fixed / flexible / deadline distinction
/// without turning into a date-picker soup.
struct TaskEditorView: View {
    /// `nil` creates a new task.
    let task: TaskItem?

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var details = ""
    @State private var importance: Importance = .normal
    @State private var timingMode: TimingMode = .unscheduled
    @State private var date = Date()
    @State private var hasLoaded = false

    private enum TimingMode: String, CaseIterable, Identifiable {
        case unscheduled
        case dueBy
        case fixed

        var id: String { rawValue }

        var title: String {
            switch self {
            case .unscheduled: return "No time"
            case .dueBy: return "Deadline"
            case .fixed: return "Set time"
            }
        }

        var footer: String {
            switch self {
            case .unscheduled:
                return "I won't schedule reminders until this has a time."
            case .dueBy:
                return "I'll spread nudges across the time you have, then a final one."
            case .fixed:
                return "I'll plan preparation and leave reminders around it."
            }
        }
    }

    var body: some View {
        Form {
            Section {
                TextField("What needs doing?", text: $title, axis: .vertical)
                    .lineLimit(1...3)
                TextField("Notes", text: $details, axis: .vertical)
                    .lineLimit(1...5)
            }

            Section {
                Picker("Priority", selection: $importance) {
                    ForEach(Importance.allCases, id: \.self) { level in
                        Text(ImportanceStyle.label(for: level)).tag(level)
                    }
                }
            }

            Section {
                Picker("Timing", selection: $timingMode) {
                    ForEach(TimingMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                if timingMode != .unscheduled {
                    DatePicker(
                        timingMode == .fixed ? "Starts" : "Due by",
                        selection: $date,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                }
            } footer: {
                Text(timingMode.footer)
            }
        }
        .navigationTitle(task == nil ? "New Task" : "Edit Task")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task {
                        await save()
                        dismiss()
                    }
                }
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onAppear(perform: loadIfNeeded)
    }

    private func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        guard let task else {
            date = model.now.addingTimeInterval(TimeSpan.hour)
            return
        }

        title = task.title
        details = task.details ?? ""
        importance = task.importance

        switch task.timing {
        case .fixed(let value):
            timingMode = .fixed
            date = value
        case .dueBy(let value):
            timingMode = .dueBy
            date = value
        case .flexible(let window):
            timingMode = .dueBy
            date = window.end
        case .unscheduled:
            timingMode = .unscheduled
            date = model.now.addingTimeInterval(TimeSpan.hour)
        }
    }

    private func save() async {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDetails = details.trimmingCharacters(in: .whitespacesAndNewlines)

        let timing: TimingPreference
        switch timingMode {
        case .unscheduled: timing = .unscheduled
        case .dueBy: timing = .dueBy(date)
        case .fixed: timing = .fixed(date)
        }

        var updated = task ?? TaskItem(title: trimmedTitle, createdAt: model.now)
        updated.title = trimmedTitle
        updated.details = trimmedDetails.isEmpty ? nil : trimmedDetails
        updated.importance = importance
        updated.timing = timing
        updated.deadline = timingMode == .unscheduled ? nil : date

        await model.updateTask(updated)
    }
}

#Preview {
    // TODO-XCODE: Verify SwiftUI preview.
    NavigationStack {
        TaskEditorView(task: nil)
    }
    .environment(AppModel(environment: AppEnvironment.makeDemo()))
}
