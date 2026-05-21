// OnboardingView.swift
// Shown once on first launch — explains the 4-step workflow then gets out of the way.

import SwiftUI

struct OnboardingView: View {

    @EnvironmentObject private var nav: AppNavigator
    @State private var isHoveringCTA = false

    private let steps: [(icon: String, title: String, detail: String)] = [
        ("folder.badge.plus",      "Select",  "Pick any folder or .zip archive containing your photos and videos"),
        ("magnifyingglass.circle", "Scan",    "Foldiq reads dates, location data, and spots duplicate files"),
        ("eye",                    "Review",  "See every planned file movement in a full preview — nothing moves until you say so"),
        ("checkmark.circle.fill",  "Apply",   "Foldiq organizes your library and writes a full undo log so you can reverse everything"),
    ]

    var body: some View {
        ZStack {
            // Blurred background that sits on top of WelcomeView
            Rectangle()
                .fill(.regularMaterial)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // ── Icon + headline ───────────────────────────────────────────
                VStack(spacing: 14) {
                    Image(systemName: "folder.badge.gearshape")
                        .font(.system(size: 64, weight: .thin))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.blue, .purple],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .symbolEffect(.pulse)

                    Text("Welcome to Foldiq")
                        .font(.system(size: 36, weight: .bold, design: .rounded))

                    Text("Here's how it works")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                Spacer().frame(height: 48)

                // ── Steps ─────────────────────────────────────────────────────
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { idx, step in
                        OnboardingStep(number: idx + 1,
                                       icon: step.icon,
                                       title: step.title,
                                       detail: step.detail)
                        if idx < steps.count - 1 {
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 28)
                        }
                    }
                }
                .frame(maxWidth: 720)

                Spacer().frame(height: 52)

                // ── CTA ───────────────────────────────────────────────────────
                Button { dismissOnboarding() } label: {
                    HStack(spacing: 10) {
                        Text("Get Started")
                            .fontWeight(.semibold)
                        Image(systemName: "arrow.right")
                    }
                    .font(.title3)
                    .padding(.horizontal, 36)
                    .padding(.vertical, 14)
                    .background(.blue, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
                    .scaleEffect(isHoveringCTA ? 1.03 : 1.0)
                    .animation(.spring(response: 0.25), value: isHoveringCTA)
                }
                .buttonStyle(.plain)
                .onHover { isHoveringCTA = $0 }

                Spacer().frame(height: 12)

                Text("Nothing is deleted without your permission.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func dismissOnboarding() {
        UserDefaults.standard.set(true, forKey: "hasSeenOnboarding")
        withAnimation(.easeInOut(duration: 0.35)) {
            nav.showOnboarding = false
        }
    }
}

// MARK: ─── Onboarding Step ────────────────────────────────────────────────────

struct OnboardingStep: View {
    let number: Int
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.12))
                    .frame(width: 56, height: 56)
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.blue)
            }
            .overlay(alignment: .topTrailing) {
                Text("\(number)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(.blue, in: Circle())
                    .offset(x: 4, y: -4)
            }

            Text(title)
                .font(.subheadline)
                .fontWeight(.semibold)

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
    }
}
