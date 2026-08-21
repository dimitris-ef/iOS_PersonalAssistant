import AssistantDomain
import SwiftUI

/// Today answers one question: what do I need to care about today?
///
/// Not a calendar. The preparation and leave rows are the assistant's own
/// additions to the day, and they sit alongside events and tasks as equals.
struct TodayScreen: View {
    @Environment(AppModel.self) private var model
    @State private var viewModel = TodayViewModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    summary

                    if let upNext = viewModel.upNext(for: model) {
                        UpNextCard(
                            item: upNext,
                            onOpen: { viewModel.open(upNext.reference) },
                            onDone: { Task { await complete(upNext) } },
                            onSnooze: { Task { await snooze(upNext) } },
                            onPreviewReminder: {
                                viewModel.simulateNextReminder(for: upNext, model: model)
                            }
                        )
                    }

                    focus

                    timeline
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.bottom, Theme.Spacing.xxl)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Today")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { SettingsToolbarButton() }
            }
            .detailSheet(route: $viewModel.route)
        }
    }

    // MARK: Sections

    private var summary: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(AppFormatters.shared.fullDate(model.now))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text(viewModel.summary(for: model))
                .font(.title3)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, Theme.Spacing.xs)
        .accessibilityElement(children: .combine)
    }

    /// The ranked list: what to do now, and why each row is there.
    ///
    /// Ordering comes from `DailyPriorityRanker` through the presenter. This
    /// view sorts nothing.
    @ViewBuilder
    private var focus: some View {
        let items = viewModel.focus(for: model)

        if !items.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                SectionHeading(text: "What to do now")

                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        TodayFocusRow(
                            item: item,
                            isLast: index == items.count - 1,
                            onOpen: { viewModel.open(.task(item.id)) },
                            onStart: { Task { await model.helpMeStart(item.id) } }
                        )
                    }
                }
                .cardSurface(padding: Theme.Spacing.lg)
            }
        }
    }

    @ViewBuilder
    private var timeline: some View {
        let items = viewModel.timeline(for: model)

        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            SectionHeading(text: "Timeline")

            if items.isEmpty {
                EmptyStateView(
                    systemImage: "sun.max",
                    title: "Nothing scheduled",
                    message: "Your day is clear. Tell me if something comes up and I'll plan around it."
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        TodayTimelineRow(
                            item: item,
                            isLast: index == items.count - 1,
                            onOpen: item.reference.map { reference in
                                { viewModel.open(reference) }
                            }
                        )
                    }
                }
                .cardSurface(padding: Theme.Spacing.lg)
            }
        }
    }

    // MARK: Actions

    private func complete(_ item: UpNextItem) async {
        switch item.reference {
        case .task(let id):
            await model.completeTask(id)
        case .event:
            model.banner = BannerMessage(
                text: "Events aren't completed — open it to change or cancel it.",
                style: .neutral
            )
        }
    }

    private func snooze(_ item: UpNextItem) async {
        switch item.reference {
        case .task(let id):
            await model.snoozeTask(id)
        case .event:
            model.banner = BannerMessage(
                text: "I'll nudge you again closer to the time.",
                style: .neutral
            )
        }
    }
}

#Preview {
    // TODO-XCODE: Verify SwiftUI preview.
    TodayScreen()
        .environment(AppModel(environment: AppEnvironment.makeDemo()))
}
