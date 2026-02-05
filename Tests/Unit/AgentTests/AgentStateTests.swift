// SPDX-License-Identifier: MIT
// AgentStateTests.swift - Unit tests for the Agent state machine per SPEC.md Section 4

import Testing
import Foundation
@testable import WellWhaddyaKnowAgent
@testable import Sensors

// MARK: - AgentState Working State Tests (SPEC.md Section 4.2)

@Suite("Agent State Machine Tests")
struct AgentStateTests {
    
    // MARK: - isWorking Truth Table (SPEC.md Section 4.2)
    // isWorking = isSystemAwake && isSessionOnConsole && !isScreenLocked
    
    @Test("isWorking is true when awake, on console, unlocked")
    func isWorkingAllTrue() {
        let state = AgentState(
            isSystemAwake: true,
            isSessionOnConsole: true,
            isScreenLocked: false
        )
        #expect(state.isWorking == true)
    }
    
    @Test("isWorking is false when system is asleep")
    func isWorkingFalseWhenAsleep() {
        let state = AgentState(
            isSystemAwake: false,
            isSessionOnConsole: true,
            isScreenLocked: false
        )
        #expect(state.isWorking == false)
    }
    
    @Test("isWorking is false when not on console")
    func isWorkingFalseWhenNotOnConsole() {
        let state = AgentState(
            isSystemAwake: true,
            isSessionOnConsole: false,
            isScreenLocked: false
        )
        #expect(state.isWorking == false)
    }
    
    @Test("isWorking is false when screen is locked")
    func isWorkingFalseWhenLocked() {
        let state = AgentState(
            isSystemAwake: true,
            isSessionOnConsole: true,
            isScreenLocked: true
        )
        #expect(state.isWorking == false)
    }
    
    @Test("isWorking is false when multiple conditions fail")
    func isWorkingFalseMultipleConditions() {
        let state = AgentState(
            isSystemAwake: false,
            isSessionOnConsole: false,
            isScreenLocked: true
        )
        #expect(state.isWorking == false)
    }
    
    // MARK: - Complete Truth Table Coverage
    
    @Test("isWorking truth table exhaustive test")
    func isWorkingTruthTableExhaustive() {
        // Test all 8 combinations
        let testCases: [(awake: Bool, console: Bool, locked: Bool, expected: Bool)] = [
            (false, false, false, false),
            (false, false, true,  false),
            (false, true,  false, false),
            (false, true,  true,  false),
            (true,  false, false, false),
            (true,  false, true,  false),
            (true,  true,  false, true),   // Only this case is working
            (true,  true,  true,  false),
        ]
        
        for tc in testCases {
            let state = AgentState(
                isSystemAwake: tc.awake,
                isSessionOnConsole: tc.console,
                isScreenLocked: tc.locked
            )
            #expect(
                state.isWorking == tc.expected,
                "awake=\(tc.awake), console=\(tc.console), locked=\(tc.locked) should be \(tc.expected)"
            )
        }
    }
    
    // MARK: - Initial State Tests (SPEC.md Section 4.3)
    
    @Test("Initial state is conservative (not working)")
    func initialStateIsConservative() {
        let initial = AgentState.initial
        #expect(initial.isWorking == false, "Initial state should be conservative (not working)")
        #expect(initial.isSystemAwake == true, "Initial assumes system is awake")
        #expect(initial.isSessionOnConsole == false, "Initial is conservative about console")
        #expect(initial.isScreenLocked == true, "Initial is conservative (assume locked)")
    }
    
    // MARK: - State from Session Tests
    
    @Test("fromSessionState creates correct state")
    func fromSessionStateCreatesCorrectState() {
        let session = SessionState(isOnConsole: true, isScreenLocked: false)
        let state = AgentState.fromSessionState(session, isSystemAwake: true)
        
        #expect(state.isSystemAwake == true)
        #expect(state.isSessionOnConsole == true)
        #expect(state.isScreenLocked == false)
        #expect(state.isWorking == true)
    }
    
    @Test("fromSessionState with asleep system is not working")
    func fromSessionStateAsleep() {
        let session = SessionState(isOnConsole: true, isScreenLocked: false)
        let state = AgentState.fromSessionState(session, isSystemAwake: false)
        
        #expect(state.isSystemAwake == false)
        #expect(state.isWorking == false)
    }
    
    @Test("fromSessionState with unknown session")
    func fromSessionStateUnknown() {
        let session = SessionState.unknown
        let state = AgentState.fromSessionState(session, isSystemAwake: true)
        
        #expect(state.isSessionOnConsole == false)
        #expect(state.isScreenLocked == true)
        #expect(state.isWorking == false)
    }
    
    // MARK: - Mutability Tests
    
    @Test("AgentState can be mutated")
    func agentStateMutability() {
        var state = AgentState.initial
        
        state.isSessionOnConsole = true
        state.isScreenLocked = false
        
        #expect(state.isWorking == true)
    }
    
    @Test("AgentState is Equatable")
    func agentStateEquatable() {
        let state1 = AgentState(isSystemAwake: true, isSessionOnConsole: true, isScreenLocked: false)
        let state2 = AgentState(isSystemAwake: true, isSessionOnConsole: true, isScreenLocked: false)
        let state3 = AgentState(isSystemAwake: false, isSessionOnConsole: true, isScreenLocked: false)
        
        #expect(state1 == state2)
        #expect(state1 != state3)
    }
}

