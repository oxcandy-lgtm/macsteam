// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Kinds of graphics backends available for Windows game rendering.
enum GraphicsBackendKind: String, Sendable, Codable, CaseIterable {
    /// DirectX Metal Translation — Apple's Metal-based D3D translation layer.
    /// Note: requires explicit external artifact; not bundled.
    case dxmt

    /// WineD3D — OpenGL-based D3D translation (built into Wine).
    case wineD3D

    /// DXVK + MoltenVK — Vulkan-based D3D translation via MoltenVK.
    /// Only available on GPUs that support Metal 3+ with geometry shaders.
    case dxvkMoltenVK

    /// External D3DMetal — provided by CrossOver or user. Not bundled,
    /// not required, not recommended as default.
    case externalD3DMetal
}
