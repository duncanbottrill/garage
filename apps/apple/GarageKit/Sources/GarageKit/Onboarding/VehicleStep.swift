import SwiftUI

/// Step 3: pick the car Garage shows, from the cars the Tesla account import found.
public struct VehicleStep: View {
    /// What the import has found so far.
    public enum Phase: Equatable, Sendable {
        /// `POST /api/vehicles/sync` is running.
        case loading
        /// The import finished.
        case loaded(VehicleSync)
        /// The import failed, with copy for the failure.
        case failed(String)
    }

    private let phase: Phase
    private let isWorking: Bool
    private let errorMessage: String?
    private let onContinue: (Vehicle) -> Void
    private let onRetry: () -> Void

    @State private var selectedID: UUID?

    /// - Parameters:
    ///   - phase: The import's progress.
    ///   - isWorking: The chosen car is being loaded.
    ///   - errorMessage: The last failure's copy from the flow.
    ///   - onContinue: Chooses a car (``AppModel/choose(_:)``).
    ///   - onRetry: Runs the import again.
    public init(
        phase: Phase,
        isWorking: Bool = false,
        errorMessage: String? = nil,
        onContinue: @escaping (Vehicle) -> Void,
        onRetry: @escaping () -> Void
    ) {
        self.phase = phase
        self.isWorking = isWorking
        self.errorMessage = errorMessage
        self.onContinue = onContinue
        self.onRetry = onRetry
    }

    /// The last six characters of a VIN, which is how Tesla's own app tells cars apart.
    public static func vinSuffix(_ vin: String) -> String {
        String(vin.suffix(6))
    }

    public var body: some View {
        OnboardingStepLayout(
            step: .chooseVehicle,
            title: "Choose your car",
            message: "This is the car Garage will show and control.",
            errorMessage: errorMessage
        ) {
            switch phase {
            case .loading:
                HStack(spacing: Tokens.Space.m) {
                    ProgressView().controlSize(.small).tint(Tokens.Colors.muted)
                    Text("Looking for cars on your Tesla account")
                        .garage(.body)
                        .foregroundStyle(Tokens.Colors.muted)
                }
            case .loaded(let sync) where sync.vehicles.isEmpty:
                VStack(spacing: Tokens.Space.l) {
                    OnboardingNotice(
                        icon: .carFront,
                        text: sync.conflicts.isEmpty
                            ? "No cars on this Tesla account yet."
                            : "This car is already linked to another Garage account.",
                        tint: Tokens.Colors.warning
                    )
                    Button("Try again", action: onRetry).onboarding(.secondary)
                }
            case .loaded(let sync):
                VStack(spacing: Tokens.Space.l) {
                    VStack(spacing: Tokens.Space.s) {
                        ForEach(sync.vehicles) { vehicle in
                            row(vehicle, selected: vehicle.id == (selectedID ?? sync.vehicles.first?.id))
                        }
                    }
                    Button("Continue") {
                        if let chosen = sync.vehicles.first(where: { $0.id == selectedID }) ?? sync.vehicles.first {
                            onContinue(chosen)
                        }
                    }
                    .onboarding(.primary, isWorking: isWorking)
                }
            case .failed(let message):
                VStack(spacing: Tokens.Space.l) {
                    OnboardingNotice(icon: .circleAlert, text: message, tint: Tokens.Colors.danger)
                    Button("Try again", action: onRetry).onboarding(.secondary)
                }
            }
        }
    }

    private func row(_ vehicle: Vehicle, selected: Bool) -> some View {
        Button {
            selectedID = vehicle.id
        } label: {
            HStack(spacing: Tokens.Space.m) {
                Icon(.carFront)
                    .foregroundStyle(selected ? Tokens.Colors.accent : Tokens.Colors.muted)
                VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                    Text(vehicle.model ?? vehicle.displayName)
                        .garage(.title)
                        .foregroundStyle(Tokens.Colors.ink)
                    Text("VIN ending \(Self.vinSuffix(vehicle.vin))")
                        .garage(.caption, tabular: true)
                        .foregroundStyle(Tokens.Colors.muted)
                }
                Spacer(minLength: 0)
                if selected {
                    Icon(.check, size: 16).foregroundStyle(Tokens.Colors.accent)
                }
            }
            .padding(Tokens.Space.l)
            .glassSurface()
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: Tokens.Radius.tile, style: .continuous)
                        .strokeBorder(Tokens.Colors.accent.opacity(Tokens.Opacity.accentStroke), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
