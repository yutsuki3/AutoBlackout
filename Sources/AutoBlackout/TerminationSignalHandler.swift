import Foundation

/// Turns SIGTERM / SIGHUP / SIGINT into a normal quit.
///
/// By default these signals kill the process on the spot, skipping `applicationShouldTerminate`, so a
/// `killall AutoBlackout` (or a script, or a logout that falls back to signals) while the built-in
/// display is off would take away the only process that can restore it. Routed into the normal quit
/// instead, the app first restores the panel and confirms it, and cancels the quit if it can't.
/// SIGKILL can't be caught; the launch self-heal and `--restore` remain the fallback for that.
final class TerminationSignalHandler {
    static let defaultSignals = [SIGTERM, SIGHUP, SIGINT]

    private var sources: [DispatchSourceSignal] = []

    /// `action` runs on the main queue each time one of `signals` arrives.
    init(signals: [Int32] = TerminationSignalHandler.defaultSignals, action: @escaping () -> Void) {
        for number in signals {
            // The default disposition must be ignored for the dispatch source to see the signal.
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler(handler: action)
            source.resume()
            sources.append(source)
        }
    }

    deinit {
        for source in sources { source.cancel() }
    }
}
