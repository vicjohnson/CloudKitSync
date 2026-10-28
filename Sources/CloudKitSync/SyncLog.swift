//
//  SyncLog.swift
//  CloudKitSync
//

/// Receives a diagnostic message from CloudKitSync. Every API that can log takes an optional one,
/// and logs nothing when it's nil, so the package stays silent unless an app opts in — for
/// example by forwarding to an `os.Logger`, or `print` while debugging a sync problem.
///
/// May be called from any thread.
public typealias SyncLog = @Sendable (String) -> Void
