// RootView.swift
// The outer shell: shows a step progress indicator at the top and
// routes to the correct screen below it.

import SwiftUI

struct RootView: View {

    @EnvironmentObject private var nav: AppNavigator

    var body: some View {
        VStack(spacing: 0) {

            // ── Step indicator (hidden on welcome) ──────────────────────────
            if nav.screen != .welcome {
                StepIndicator(current: nav.screen)
                    .padding(.horizontal, 40)
                    .padding(.vertical, 14)
                    .background(.bar)

                Divider()
            }

            // ── Screen content ──────────────────────────────────────────────
            Group {
                switch nav.screen {
                case .welcome:  WelcomeView()
                case .scan:     ScanView()
                case .settings: SettingsStepView()
                case .preview:  PreviewView()
                case .apply:    ApplyView()
                case .report:   ReportView()
                }
            }
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal:   .move(edge: .leading).combined(with: .opacity)
            ))
        }
        .animation(.easeInOut(duration: 0.25), value: nav.screen)
        // ── First-launch onboarding ──────────────────────────────────────────
        .overlay {
            if nav.showOnboarding {
                OnboardingView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: nav.showOnboarding)
        .alert("Error", isPresented: $nav.showingError) {
            Button("OK") { nav.showingError = false }
        } message: {
            Text(nav.errorMessage ?? "An unknown error occurred.")
        }
    }
}

// MARK: ─── Step Indicator ─────────────────────────────────────────────────────

struct StepIndicator: View {
    let current: AppScreen

    // Only show the wizard steps (not welcome)
    private let steps: [AppScreen] = [.scan, .settings, .preview, .apply, .report]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.element) { idx, step in
                StepDot(step: step, state: dotState(for: step))

                if idx < steps.count - 1 {
                    Rectangle()
                        .fill(current.rawValue > step.rawValue ? Color.accentColor : Color.secondary.opacity(0.2))
                        .frame(height: 2)
                }
            }
        }
    }

    private func dotState(for step: AppScreen) -> StepDotState {
        if step == current         { return .active }
        if step.rawValue < current.rawValue { return .done }
        return .future
    }
}

enum StepDotState { case done, active, future }

struct StepDot: View {
    let step: AppScreen
    let state: StepDotState

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(fillColor)
                    .frame(width: 28, height: 28)

                if state == .done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Image(systemName: step.icon)
                        .font(.system(size: 12))
                        .foregroundStyle(state == .active ? .white : .secondary)
                }
            }
            Text(step.title)
                .font(.caption2)
                .foregroundStyle(state == .future ? .secondary : .primary)
        }
    }

    var fillColor: Color {
        switch state {
        case .done:   return .accentColor
        case .active: return .accentColor
        case .future: return Color.secondary.opacity(0.15)
        }
    }
}
