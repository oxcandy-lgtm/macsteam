// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Result of inspecting a graphics backend's availability on the host.
struct GraphicsBackendInspection: Sendable, Equatable {
    let kind: GraphicsBackendKind
    let available: Bool
    let reason: String?
}

/// Registry that determines which graphics backends are available
/// on the current host.
///
/// Preference order:
/// 1. DXMT (when artifact exists and is valid)
/// 2. WineD3D (built into Wine, always available)
/// 3. DXVK + MoltenVK (when GPU supports geometry shaders)
/// 4. External D3DMetal (user-provided, optional)
///
/// **U1R6:** D3DMetal is not bundled, not required, not default.
/// External D3DMetal is treated as a user-provided Oracle-only backend
/// and never auto-selected.
struct GraphicsBackendRegistry: Sendable {
    /// Inspect available backends in preference order.
    func inspect() -> [GraphicsBackendInspection] {
        [
            dxmtInspection(),
            wineD3DInspection(),
            dxvkMoltenVKInspection(),
            externalD3DMetalInspection(),
        ]
    }

    /// Select the best available backend.
    func selectPreferred() -> GraphicsBackendKind? {
        let available = inspect().filter { $0.available }
        return available.first?.kind
    }

    // MARK: - Private

    private func dxmtInspection() -> GraphicsBackendInspection {
        // DXMT requires explicit user-provided artifact.
        // Not bundled, not auto-detected. Placeholder.
        GraphicsBackendInspection(
            kind: .dxmt,
            available: false,
            reason: "DXMT artifact not present. User must provide an explicit DXMT build."
        )
    }

    private func wineD3DInspection() -> GraphicsBackendInspection {
        // WineD3D is always available when Wine is present.
        GraphicsBackendInspection(
            kind: .wineD3D,
            available: true,
            reason: nil
        )
    }

    private func dxvkMoltenVKInspection() -> GraphicsBackendInspection {
        // M1 Pro has geometry shader support in Metal, but MoltenVK does
        // not translate them. DXVK 3.x cannot run on Apple Silicon.
        GraphicsBackendInspection(
            kind: .dxvkMoltenVK,
            available: false,
            reason: "DXVK requires geometry shaders. Apple GPUs via MoltenVK lack geometry shader support."
        )
    }

    private func externalD3DMetalInspection() -> GraphicsBackendInspection {
        // D3DMetal is provided by CrossOver. Not bundled, not required.
        let crossoverURL = URL(fileURLWithPath: "/Applications/CrossOver.app")
        let crossoverExists = FileManager.default.fileExists(atPath: crossoverURL.path)
        return GraphicsBackendInspection(
            kind: .externalD3DMetal,
            available: crossoverExists,
            reason: crossoverExists
                ? "D3DMetal available via CrossOver (Oracle-only, not required for independent runtime)"
                : "No external D3DMetal source found"
        )
    }
}
