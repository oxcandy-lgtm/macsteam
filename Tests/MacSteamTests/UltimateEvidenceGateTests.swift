// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
import Foundation
import MacsTeamNavigationCore
@testable import MacSteam

// MARK: - U1R17-D evidence-gate tests
//
// Production-linked proof: the SAME presentation descriptor, Inspect lane,
// and evidence helper that production consumes are exercised here — no
// parallel test-only mappings.

// MARK: - Unified page presentation contract

struct UnifiedPagePresentationTests {
    @Test("all six pages resolve to six distinct presentations")
    func sixPages_sixDistinctPresentations() {
        let pages = InstallerPage.allCases
        let presentations = pages.map { UltimatePageResolver.presentation(for: $0) }
        #expect(presentations.count == 6)
        #expect(Set(presentations.map(\.page)).count == 6)
        #expect(Set(presentations.map(\.contentKind)).count == 6)
    }

    @Test("page, footerPage, title, step, content derive from the same currentPage")
    func unifiedContract_sameCurrentPageOrigin() {
        for page in InstallerPage.allCases {
            let presentation = UltimatePageResolver.presentation(for: page)
            #expect(presentation.page == page)
            #expect(presentation.footerPage == page)
            #expect(presentation.contentKind == UltimatePageResolver.contentKind(for: page))
            #expect(presentation.title == UltimatePageResolver.title(for: page))
            #expect(presentation.stepNumber == UltimatePageResolver.stepNumber(for: page))
            #expect(presentation.hasCanonicalNavigation == true)
        }
    }

    @Test("steam installer and client presentations have distinct modes")
    func steamModes_distinct() {
        let installer = UltimatePageResolver.presentation(for: .steamInstaller)
        let client = UltimatePageResolver.presentation(for: .steamClient)
        #expect(installer.steamMode == .installer)
        #expect(client.steamMode == .client)
        #expect(installer.steamMode != client.steamMode)
        // Non-Steam pages carry no Steam mode.
        for page in [InstallerPage.runtime, .environment, .cloverPit, .diagnostics] {
            #expect(UltimatePageResolver.presentation(for: page).steamMode == nil)
        }
    }

    @Test("diagnostics presentation carries canonical navigation")
    func diagnostics_hasCanonicalNavigation() {
        let presentation = UltimatePageResolver.presentation(for: .diagnostics)
        #expect(presentation.hasCanonicalNavigation == true)
        #expect(presentation.footerPage == .diagnostics)
    }
}

// MARK: - Prefix Inspect lane (production action)

@MainActor
struct PrefixInspectLaneTests {
    let testPrefixURL = URL(fileURLWithPath: "/tmp/prefix")

    func makePrefixLayout(root: URL) -> PrefixLayout {
        PrefixLayout(
            root: root,
            driveC: root.appendingPathComponent("drive_c"),
            dosdevices: root.appendingPathComponent("dosdevices"),
            systemReg: root.appendingPathComponent("system.reg"),
            userReg: root.appendingPathComponent("user.reg"),
            windowsSteamCandidates: []
        )
    }

    func makeValidPrefixInspection(root: URL) -> PrefixInspection {
        PrefixInspection(
            prefixURL: root,
            driveCExists: true,
            hasWinePrefix: true,
            hasSteam: false,
            isValid: true
        )
    }

    @Test("production Inspect lane calls coordinator canonical inspection exactly once")
    func inspectLane_exactlyOneCoordinatorCall() async {
        let coordinator = UltimateSetupCoordinator()
        let fake = FakePrefixInspector(inspection: makeValidPrefixInspection(root: testPrefixURL))
        coordinator.prefixInspectorProvider = { fake }
        coordinator.prefixLayout = makePrefixLayout(root: testPrefixURL)

        let action = PrefixInspectAction.production(coordinator: coordinator)
        await action.run()

        #expect(fake.inspectCallCount == 1)
        #expect(coordinator.prefixInspection != nil)
        #expect(coordinator.canonicalPrefixEvidenceValid == true)
    }

    @Test("the view's default Inspect lane is the production lane")
    func viewDefaultLane_isProductionLane() async {
        let coordinator = UltimateSetupCoordinator()
        let fake = FakePrefixInspector(inspection: makeValidPrefixInspection(root: testPrefixURL))
        coordinator.prefixInspectorProvider = { fake }
        coordinator.prefixLayout = makePrefixLayout(root: testPrefixURL)

        // The view's stored action IS what the Inspect button invokes.
        let view = PrefixSetupView(
            coordinator: coordinator,
            presentation: UltimatePageResolver.presentation(for: .environment)
        )
        await view.inspectAction.run()

        #expect(fake.inspectCallCount == 1)
        #expect(coordinator.canonicalPrefixEvidenceValid == true)
        // The view carries the SAME presentation the root derives.
        #expect(view.presentation == UltimatePageResolver.presentation(for: .environment))
    }
}

// MARK: - Prefix acquisition paths (evidence established on all three)

@MainActor
struct PrefixAcquisitionEvidenceTests {
    let testPrefixURL = URL(fileURLWithPath: "/tmp/prefix")

    func makePrefixLayout(root: URL) -> PrefixLayout {
        PrefixLayout(
            root: root,
            driveC: root.appendingPathComponent("drive_c"),
            dosdevices: root.appendingPathComponent("dosdevices"),
            systemReg: root.appendingPathComponent("system.reg"),
            userReg: root.appendingPathComponent("user.reg"),
            windowsSteamCandidates: []
        )
    }

    func makeValidPrefixInspection(root: URL) -> PrefixInspection {
        PrefixInspection(
            prefixURL: root,
            driveCExists: true,
            hasWinePrefix: true,
            hasSteam: false,
            isValid: true
        )
    }

    @Test("existing canonical path establishes bound evidence")
    func existingCanonicalPath_establishesEvidence() async {
        let coordinator = UltimateSetupCoordinator()
        let fake = FakePrefixInspector(inspection: makeValidPrefixInspection(root: testPrefixURL))
        coordinator.prefixInspectorProvider = { fake }
        let layout = makePrefixLayout(root: testPrefixURL)

        let evidence = coordinator.establishPrefixEvidence(
            for: layout,
            source: .existingCanonical
        )

        // Layout set, inspection generated, bound to canonical root.
        #expect(coordinator.prefixLayout?.root == layout.root)
        #expect(coordinator.prefixInspection != nil)
        #expect(evidence.isValid == true)
        #expect(coordinator.canonicalPrefixEvidenceValid == true)
        #expect(fake.inspectCallCount == 1)
    }

    @Test("production router: validated layout branch uses existingCanonical source")
    func router_validatedBranch_establishesMatchingEvidence() async {
        let coordinator = UltimateSetupCoordinator()
        let fake = FakePrefixInspector(inspection: makeValidPrefixInspection(root: testPrefixURL))
        coordinator.prefixInspectorProvider = { fake }
        let layout = makePrefixLayout(root: testPrefixURL)

        let acquisition = coordinator.establishExistingPrefixAcquisition(
            validatedLayout: layout,
            adoptedLayout: nil
        )

        #expect(acquisition?.layout.root == layout.root)
        #expect(acquisition?.source == .existingCanonical)
        #expect(coordinator.prefixInspection != nil)
        #expect(coordinator.canonicalPrefixEvidenceValid == true)
        #expect(fake.inspectCallCount == 1)
    }

    @Test("production router: adopted branch uses adoptedSteam source")
    func router_adoptedBranch_establishesMatchingEvidence() async {
        let coordinator = UltimateSetupCoordinator()
        let fake = FakePrefixInspector(inspection: makeValidPrefixInspection(root: testPrefixURL))
        coordinator.prefixInspectorProvider = { fake }
        let layout = makePrefixLayout(root: testPrefixURL)

        let acquisition = coordinator.establishExistingPrefixAcquisition(
            validatedLayout: nil,
            adoptedLayout: layout
        )

        #expect(acquisition?.layout.root == layout.root)
        #expect(acquisition?.source == .adoptedSteam)
        #expect(coordinator.prefixInspection != nil)
        #expect(coordinator.canonicalPrefixEvidenceValid == true)
        #expect(fake.inspectCallCount == 1)
    }

    @Test("every page carries canonical navigation capability via derivation")
    func allPages_haveCanonicalNavigation() {
        for page in InstallerPage.allCases {
            let presentation = UltimatePageResolver.presentation(for: page)
            #expect(presentation.hasCanonicalNavigation == true)
            #expect(presentation.hasCanonicalNavigation
                    == UltimatePageResolver.hasCanonicalNavigation(for: page))
        }
    }

    @Test("production router: neither existing nor adopted selects the new path")
    func router_noExistingOrAdopted_returnsNil() async {
        let coordinator = UltimateSetupCoordinator()

        let acquisition = coordinator.establishExistingPrefixAcquisition(
            validatedLayout: nil,
            adoptedLayout: nil
        )

        // The caller then uses .newlyInitialized after wineboot.
        #expect(acquisition == nil)
        #expect(coordinator.prefixInspection == nil)
    }

    @Test("adopted Steam path establishes bound evidence")
    func adoptedSteamPath_establishesEvidence() async {
        let coordinator = UltimateSetupCoordinator()
        let fake = FakePrefixInspector(inspection: makeValidPrefixInspection(root: testPrefixURL))
        coordinator.prefixInspectorProvider = { fake }
        let layout = makePrefixLayout(root: testPrefixURL)

        let evidence = coordinator.establishPrefixEvidence(
            for: layout,
            source: .adoptedSteam
        )

        #expect(coordinator.prefixLayout?.root == layout.root)
        #expect(coordinator.prefixInspection != nil)
        #expect(evidence.isValid == true)
        #expect(coordinator.canonicalPrefixEvidenceValid == true)
        #expect(fake.inspectCallCount == 1)
    }

    @Test("newly initialized path establishes bound evidence")
    func newlyInitializedPath_establishesEvidence() async {
        let coordinator = UltimateSetupCoordinator()
        let fake = FakePrefixInspector(inspection: makeValidPrefixInspection(root: testPrefixURL))
        coordinator.prefixInspectorProvider = { fake }
        let layout = makePrefixLayout(root: testPrefixURL)

        let evidence = coordinator.establishPrefixEvidence(
            for: layout,
            source: .newlyInitialized
        )

        #expect(coordinator.prefixLayout?.root == layout.root)
        #expect(coordinator.prefixInspection != nil)
        #expect(evidence.isValid == true)
        #expect(coordinator.canonicalPrefixEvidenceValid == true)
        #expect(fake.inspectCallCount == 1)
    }

    @Test("evidence exists immediately after establishment (before any early return)")
    func evidenceExistsBeforeEarlyReturn() async {
        let coordinator = UltimateSetupCoordinator()
        let fake = FakePrefixInspector(inspection: makeValidPrefixInspection(root: testPrefixURL))
        coordinator.prefixInspectorProvider = { fake }
        let layout = makePrefixLayout(root: testPrefixURL)

        // The establish call IS the pre-early-return hook: after it returns,
        // evidence is present and bound — a Steam-ready early return after
        // this point can never skip inspection.
        _ = coordinator.establishPrefixEvidence(for: layout, source: .adoptedSteam)

        #expect(coordinator.prefixInspection != nil)
        #expect(coordinator.canonicalPrefixEvidenceValid == true)
        #expect(coordinator.computePageCompletion()[.environment] == true)
    }

    @Test("stale evidence does not survive a layout root change")
    func staleEvidence_clearedOnLayoutChange() async {
        let coordinator = UltimateSetupCoordinator()
        let rootA = testPrefixURL
        coordinator.prefixLayout = makePrefixLayout(root: rootA)
        coordinator.prefixInspection = makeValidPrefixInspection(root: rootA)
        #expect(coordinator.canonicalPrefixEvidenceValid == true)

        let rootB = URL(fileURLWithPath: "/tmp/prefix-b")
        coordinator.prefixLayout = makePrefixLayout(root: rootB)

        #expect(coordinator.prefixInspection == nil)
        #expect(coordinator.canonicalPrefixEvidenceValid == false)

        // Re-establishing on the new root binds fresh evidence.
        let fake = FakePrefixInspector(inspection: makeValidPrefixInspection(root: rootB))
        coordinator.prefixInspectorProvider = { fake }
        _ = coordinator.establishPrefixEvidence(
            for: makePrefixLayout(root: rootB),
            source: .newlyInitialized
        )
        #expect(coordinator.canonicalPrefixEvidenceValid == true)
        #expect(fake.inspectCallCount == 1)
    }
}

// MARK: - Fake inspector

final class FakePrefixInspector: PrefixInspecting {
    var inspection: PrefixInspection
    var inspectCallCount = 0

    init(inspection: PrefixInspection) {
        self.inspection = inspection
    }

    func inspect(url: URL) -> PrefixInspection {
        inspectCallCount += 1
        return inspection
    }
}
