//
//  BodyTrace.swift
//  HT Edit
//
//  Debug-only: set HTEDIT_TRACE_BODIES=1 to log why views re-render
//  (SwiftUI's _printChanges), to diagnose layout/render loops.
//

#if DEBUG
import Foundation

enum BodyTrace {
    static var isEnabled: Bool { getenv("HTEDIT_TRACE_BODIES") != nil }
}
#endif
