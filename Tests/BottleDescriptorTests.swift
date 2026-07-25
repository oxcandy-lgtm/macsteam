// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import MacSteam

struct BottleDescriptorTests {

    @Test func descriptorEquality() {
        let url1 = URL(fileURLWithPath: "/tmp/Bottles/Steam")
        let url2 = URL(fileURLWithPath: "/tmp/Bottles/Steam")
        let steamURL = URL(fileURLWithPath: "/tmp/Bottles/Steam/drive_c/Program Files (x86)/Steam/steam.exe")

        let a = BottleDescriptor(name: "Steam", rootURL: url1, steamExecutableURL: steamURL)
        let b = BottleDescriptor(name: "Steam", rootURL: url2, steamExecutableURL: steamURL)
        #expect(a == b)
    }

    @Test func descriptorNoSteam() {
        let desc = BottleDescriptor(
            name: "Default",
            rootURL: URL(fileURLWithPath: "/tmp/Bottles/Default"),
            steamExecutableURL: nil
        )
        #expect(desc.steamExecutableURL == nil)
    }
}

struct LaunchPlanTests {

    @Test func launchPlanEquality() {
        let a = LaunchPlan(
            runtimeExecutable: URL(fileURLWithPath: "/usr/bin/wine"),
            arguments: ["--bottle", "Steam", "--cx-app", "steam.exe"],
            mode: .detached
        )
        let b = LaunchPlan(
            runtimeExecutable: URL(fileURLWithPath: "/usr/bin/wine"),
            arguments: ["--bottle", "Steam", "--cx-app", "steam.exe"],
            mode: .detached
        )
        #expect(a == b)

        let c = LaunchPlan(
            runtimeExecutable: URL(fileURLWithPath: "/usr/bin/wine"),
            arguments: ["--bottle", "Steam", "--cx-app", "steam.exe"],
            mode: .waitForExit
        )
        #expect(a != c)  // Different mode
    }

    @Test func launchModeCases() {
        let detached = LaunchPlan(
            runtimeExecutable: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: [],
            mode: .detached
        )
        let wait = LaunchPlan(
            runtimeExecutable: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: [],
            mode: .waitForExit
        )
        #expect(detached.mode != wait.mode)
    }
}
