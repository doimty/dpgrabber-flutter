// DPGrabber Flutter - user-requested iOS audio keep-alive.
//
// AVAudioSession calls may synchronously wait for mediaserverd. The driver
// owns the session and audio graph on a private serial queue; this state
// machine and all Flutter replies stay asynchronous on the main queue.

import AVFoundation
import CallKit
import Foundation
import UIKit

protocol KeepAliveAudioDriving: AnyObject {
  func start(completion: @escaping (Bool, String?) -> Void)
  func stop(deactivateSession: Bool, completion: @escaping () -> Void)
  func isRunning(completion: @escaping (Bool) -> Void)
}

protocol KeepAliveScheduledTask: AnyObject {
  func cancel()
}

protocol KeepAliveScheduling: AnyObject {
  func schedule(
    after delay: TimeInterval,
    repeating interval: TimeInterval?,
    _ action: @escaping () -> Void
  ) -> KeepAliveScheduledTask
}

private final class DispatchKeepAliveScheduledTask: KeepAliveScheduledTask {
  private let timer: DispatchSourceTimer

  init(
    after delay: TimeInterval,
    repeating interval: TimeInterval?,
    action: @escaping () -> Void
  ) {
    timer = DispatchSource.makeTimerSource(queue: .main)
    if let interval {
      timer.schedule(
        deadline: .now() + delay,
        repeating: interval,
        leeway: .milliseconds(250)
      )
    } else {
      timer.schedule(deadline: .now() + delay)
    }
    timer.setEventHandler(handler: action)
    timer.resume()
  }

  func cancel() {
    timer.cancel()
  }
}

final class DispatchKeepAliveScheduler: KeepAliveScheduling {
  func schedule(
    after delay: TimeInterval,
    repeating interval: TimeInterval?,
    _ action: @escaping () -> Void
  ) -> KeepAliveScheduledTask {
    DispatchKeepAliveScheduledTask(
      after: delay,
      repeating: interval,
      action: action
    )
  }
}

/// Owns AVAudioSession, AVAudioEngine and AVAudioPlayerNode exclusively on
/// one queue. This ordering is important when stop arrives during activation
/// and a new start follows immediately: queued stop always lands between the
/// two starts, and an old completion cannot mutate the newer graph.
final class AVAudioKeepAliveDriver: KeepAliveAudioDriving {
  private let queue: DispatchQueue
  private let session: AVAudioSession
  private var engine: AVAudioEngine?
  private var player: AVAudioPlayerNode?
  private var ownsSession = false

  init(
    queue: DispatchQueue = DispatchQueue(label: "com.doimty.dpgrabber.audio-keep-alive"),
    session: AVAudioSession = .sharedInstance()
  ) {
    self.queue = queue
    self.session = session
  }

  func start(completion: @escaping (Bool, String?) -> Void) {
    queue.async { [self] in
      stopGraph(deactivateSession: false)
      do {
        try session.setCategory(
          .playback,
          mode: .default,
          options: [.mixWithOthers]
        )
        try session.setActive(true)
        ownsSession = true

        let newEngine = AVAudioEngine()
        let newPlayer = AVAudioPlayerNode()
        newEngine.attach(newPlayer)
        guard let format = AVAudioFormat(
          standardFormatWithSampleRate: 44_100,
          channels: 1
        ), let buffer = AVAudioPCMBuffer(
          pcmFormat: format,
          frameCapacity: AVAudioFrameCount(format.sampleRate)
        ), let samples = buffer.floatChannelData else {
          throw DriverError.audioEngine
        }
        for index in 0..<Int(buffer.frameCapacity) {
          samples[0][index] = 0
        }
        buffer.frameLength = buffer.frameCapacity
        newEngine.connect(newPlayer, to: newEngine.mainMixerNode, format: format)
        newEngine.mainMixerNode.outputVolume = 0.001
        newPlayer.scheduleBuffer(buffer, at: nil, options: .loops)
        try newEngine.start()
        newPlayer.play()
        guard newEngine.isRunning && newPlayer.isPlaying else {
          throw DriverError.audioEngine
        }
        engine = newEngine
        player = newPlayer
        DispatchQueue.main.async { completion(true, nil) }
      } catch is DriverError {
        stopGraph(deactivateSession: true)
        DispatchQueue.main.async { completion(false, "audioEngineFailed") }
      } catch {
        stopGraph(deactivateSession: true)
        DispatchQueue.main.async { completion(false, "audioSessionFailed") }
      }
    }
  }

  func stop(deactivateSession: Bool, completion: @escaping () -> Void) {
    queue.async { [self] in
      stopGraph(deactivateSession: deactivateSession)
      DispatchQueue.main.async(execute: completion)
    }
  }

  func isRunning(completion: @escaping (Bool) -> Void) {
    queue.async { [self] in
      let running = engine?.isRunning == true && player?.isPlaying == true
      DispatchQueue.main.async { completion(running) }
    }
  }

  private func stopGraph(deactivateSession: Bool) {
    player?.stop()
    engine?.stop()
    player = nil
    engine = nil
    if deactivateSession && ownsSession {
      try? session.setActive(false, options: .notifyOthersOnDeactivation)
      ownsSession = false
    }
  }

  private enum DriverError: Error {
    case audioEngine
  }
}

final class AudioKeepAlive: NSObject, CXCallObserverDelegate {
  enum State: String {
    case stopped
    case running
    case interrupted
    case recovering
    case failed
  }

  private enum Reason {
    static let userStart = "userStart"
    static let userStop = "userStop"
    static let background = "background"
    static let foreground = "foreground"
    static let interruption = "interruption"
    static let interruptionEnded = "interruptionEnded"
    static let secondaryAudioHintEnded = "secondaryAudioHintEnded"
    static let resumeNotRequested = "resumeNotRequested"
    static let callActive = "callActive"
    static let callEnded = "callEnded"
    static let mediaServicesLost = "mediaServicesLost"
    static let mediaServicesReset = "mediaServicesReset"
    static let routeChanged = "routeChanged"
    static let engineConfigurationChanged = "engineConfigurationChanged"
    static let audioSessionFailed = "audioSessionFailed"
    static let audioEngineFailed = "audioEngineFailed"
    static let audioNotRunning = "audioNotRunning"
    static let retryLimitExceeded = "retryLimitExceeded"
  }

  private static let healthInterval: TimeInterval = 5
  private static let retryDelays: [TimeInterval] = [0.5, 1, 2, 4, 8]
  private static let maxRetryCount = 5

  private(set) var state: State = .stopped
  private(set) var reason: String?

  private let driver: KeepAliveAudioDriving
  private let scheduler: KeepAliveScheduling
  private let notificationCenter: NotificationCenter
  private var callObserver: CXCallObserver?
  private var observesSystemCalls: Bool
  private var observers: [NSObjectProtocol] = []

  private var wantsRunning = false
  private var intentGeneration: UInt = 0
  private var appInBackground = false
  private var activeCall = false
  private var interruptionActive = false
  private var interruptionResumeDenied = false
  private var mediaServicesUnavailable = false
  private var awaitingUserAfterMediaReset = false
  private var retryTask: KeepAliveScheduledTask?
  private var retryGeneration: UInt = 0
  private var retryCount = 0
  private var healthTask: KeepAliveScheduledTask?

  init(
    driver: KeepAliveAudioDriving = AVAudioKeepAliveDriver(),
    scheduler: KeepAliveScheduling = DispatchKeepAliveScheduler(),
    notificationCenter: NotificationCenter = .default,
    callObserver: CXCallObserver? = nil,
    observesSystemCalls: Bool = true
  ) {
    self.driver = driver
    self.scheduler = scheduler
    self.notificationCenter = notificationCenter
    self.callObserver = callObserver
    self.observesSystemCalls = observesSystemCalls
    super.init()
    if let callObserver {
      callObserver.setDelegate(self, queue: .main)
      activeCall = callObserver.calls.contains { !$0.hasEnded }
    } else if observesSystemCalls {
      let observer = CXCallObserver()
      observer.setDelegate(self, queue: .main)
      self.callObserver = observer
      activeCall = observer.calls.contains { !$0.hasEnded }
    }
    installObservers()
  }

  deinit {
    retryTask?.cancel()
    healthTask?.cancel()
    for observer in observers {
      notificationCenter.removeObserver(observer)
    }
    driver.stop(deactivateSession: true) {}
  }

  /// Completes with true only after the driver confirms the engine and player
  /// are actually running. Failed initial attempts return false while bounded
  /// recovery continues independently.
  func start(completion: @escaping (Bool) -> Void) {
    dispatchPrecondition(condition: .onQueue(.main))
    intentGeneration &+= 1
    let generation = intentGeneration
    wantsRunning = true
    retryCount = 0
    cancelRetry()
    interruptionActive = false
    interruptionResumeDenied = false
    awaitingUserAfterMediaReset = false

    guard !activeCall else {
      setState(.interrupted, reason: Reason.callActive)
      completion(false)
      return
    }
    guard !mediaServicesUnavailable else {
      setState(.interrupted, reason: Reason.mediaServicesLost)
      completion(false)
      return
    }

    driver.isRunning { [weak self] running in
      guard let self else { completion(false); return }
      guard self.isCurrent(generation) else { completion(false); return }
      guard self.recoveryIsAllowed else {
        self.setBlockedState()
        completion(false)
        return
      }
      if running {
        self.armHealthTimer()
        self.setState(.running, reason: nil)
        completion(true)
      } else {
        self.activate(reason: Reason.userStart, generation: generation, completion: completion)
      }
    }
  }

  /// Invalidates queued callbacks immediately, then stops the graph in driver
  /// queue order. The completion runs after audio/session teardown is done.
  func stop(completion: @escaping () -> Void = {}) {
    dispatchPrecondition(condition: .onQueue(.main))
    intentGeneration &+= 1
    wantsRunning = false
    retryCount = 0
    cancelRetry()
    cancelHealthTimer()
    interruptionActive = false
    interruptionResumeDenied = false
    awaitingUserAfterMediaReset = false
    setState(.stopped, reason: Reason.userStop)
    driver.stop(deactivateSession: true, completion: completion)
  }

  func isRunning(completion: @escaping (Bool) -> Void) {
    dispatchPrecondition(condition: .onQueue(.main))
    let generation = intentGeneration
    driver.isRunning { [weak self] running in
      guard let self, self.isCurrent(generation) else {
        completion(false)
        return
      }
      guard self.recoveryIsAllowed else {
        self.setBlockedState()
        completion(false)
        return
      }
      if running {
        self.setState(.running, reason: nil)
        completion(self.wantsRunning)
      } else {
        self.recoverIfNeeded(reason: Reason.audioNotRunning)
        completion(false)
      }
    }
  }

  func status(completion: @escaping ([String: Any]) -> Void) {
    dispatchPrecondition(condition: .onQueue(.main))
    let generation = intentGeneration
    driver.isRunning { [weak self] running in
      guard let self else {
        completion(["state": State.stopped.rawValue])
        return
      }
      if self.isCurrent(generation) {
        if !self.recoveryIsAllowed {
          self.setBlockedState()
        } else if running {
          self.setState(.running, reason: nil)
        } else {
          self.recoverIfNeeded(reason: Reason.audioNotRunning)
        }
      }
      completion(self.statusSnapshot())
    }
  }

  func sceneDidBecomeActive() {
    dispatchPrecondition(condition: .onQueue(.main))
    let returnedFromBackground = appInBackground
    appInBackground = false
    let releasedMediaResetGate = awaitingUserAfterMediaReset
    if awaitingUserAfterMediaReset {
      awaitingUserAfterMediaReset = false
    }
    guard wantsRunning else { return }
    if activeCall {
      setState(.interrupted, reason: Reason.callActive)
    } else if interruptionResumeDenied || interruptionActive {
      interruptionActive = false
      interruptionResumeDenied = false
      scheduleRecovery(reason: Reason.foreground, resetBudget: true)
    } else if mediaServicesUnavailable {
      setState(.interrupted, reason: Reason.mediaServicesLost)
    } else {
      inspectHealth(
        reason: Reason.foreground,
        resetBudget: returnedFromBackground || releasedMediaResetGate
      )
    }
  }

  private func sceneDidEnterBackground() {
    dispatchPrecondition(condition: .onQueue(.main))
    appInBackground = true
    guard wantsRunning else { return }
    inspectHealth(reason: Reason.background, resetBudget: false)
  }

  private func installObservers() {
    let center = notificationCenter
    observe(center, UIApplication.didEnterBackgroundNotification) { [weak self] _ in
      self?.sceneDidEnterBackground()
    }
    observe(center, UIApplication.didBecomeActiveNotification) { [weak self] _ in
      self?.sceneDidBecomeActive()
    }
    observe(center, AVAudioSession.interruptionNotification) { [weak self] note in
      self?.handleInterruption(note)
    }
    observe(center, AVAudioSession.silenceSecondaryAudioHintNotification) { [weak self] note in
      self?.handleSilenceSecondaryAudioHint(note)
    }
    observe(center, AVAudioSession.routeChangeNotification) { [weak self] _ in
      self?.inspectHealth(reason: Reason.routeChanged, resetBudget: false)
    }
    observe(center, AVAudioSession.mediaServicesWereLostNotification) { [weak self] _ in
      self?.handleMediaServicesLost()
    }
    observe(center, AVAudioSession.mediaServicesWereResetNotification) { [weak self] _ in
      self?.handleMediaServicesReset()
    }
    observe(center, .AVAudioEngineConfigurationChange) { [weak self] _ in
      self?.inspectHealth(reason: Reason.engineConfigurationChanged, resetBudget: false)
    }
  }

  private func observe(
    _ center: NotificationCenter,
    _ name: Notification.Name,
    handler: @escaping (Notification) -> Void
  ) {
    let token = center.addObserver(forName: name, object: nil, queue: .main, using: handler)
    observers.append(token)
  }

  private func handleInterruption(_ note: Notification) {
    guard let raw = uintValue(note.userInfo?[AVAudioSessionInterruptionTypeKey]),
          let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
    switch type {
    case .began:
      interruptionActive = true
      interruptionResumeDenied = false
      cancelRetry()
      cancelHealthTimer()
      driver.stop(deactivateSession: false) {}
      setState(.interrupted, reason: activeCall ? Reason.callActive : Reason.interruption)
    case .ended:
      let rawOptions = uintValue(note.userInfo?[AVAudioSessionInterruptionOptionKey]) ?? 0
      let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
      let resumeAllowed = options.contains(.shouldResume) || !appInBackground
      guard wantsRunning else { return }
      interruptionActive = !resumeAllowed
      interruptionResumeDenied = !resumeAllowed
      guard !activeCall else {
        setState(.interrupted, reason: Reason.callActive)
        return
      }
      if resumeAllowed {
        scheduleRecovery(reason: Reason.interruptionEnded, resetBudget: true)
      } else {
        setState(.interrupted, reason: Reason.resumeNotRequested)
      }
    @unknown default:
      break
    }
  }

  private func handleSilenceSecondaryAudioHint(_ note: Notification) {
    guard let raw = uintValue(
      note.userInfo?[AVAudioSessionSilenceSecondaryAudioHintTypeKey]
    ), let type = AVAudioSession.SilenceSecondaryAudioHintType(rawValue: raw),
      type == .end else { return }
    guard wantsRunning, !activeCall, !interruptionActive,
          !interruptionResumeDenied, !mediaServicesUnavailable,
          !awaitingUserAfterMediaReset else { return }
    inspectHealth(reason: Reason.secondaryAudioHintEnded, resetBudget: true)
  }

  private func handleMediaServicesLost() {
    mediaServicesUnavailable = true
    awaitingUserAfterMediaReset = false
    cancelRetry()
    cancelHealthTimer()
    driver.stop(deactivateSession: false) {}
    if wantsRunning {
      setState(.interrupted, reason: Reason.mediaServicesLost)
    }
  }

  private func handleMediaServicesReset() {
    mediaServicesUnavailable = false
    awaitingUserAfterMediaReset = true
    cancelRetry()
    cancelHealthTimer()
    driver.stop(deactivateSession: false) {}
    if wantsRunning {
      setState(.interrupted, reason: Reason.mediaServicesReset)
    }
  }

  private func inspectHealth(reason healthReason: String, resetBudget: Bool) {
    guard wantsRunning else { return }
    let generation = intentGeneration
    driver.isRunning { [weak self] running in
      guard let self, self.isCurrent(generation), self.wantsRunning else { return }
      guard self.recoveryIsAllowed else {
        self.setBlockedState()
        return
      }
      if running {
        self.armHealthTimer()
        self.setState(.running, reason: nil)
      } else {
        self.scheduleRecovery(reason: healthReason, resetBudget: resetBudget)
      }
    }
  }

  private func recoverIfNeeded(reason healthReason: String) {
    guard wantsRunning, !activeCall, !interruptionActive,
          !interruptionResumeDenied, !mediaServicesUnavailable,
          !awaitingUserAfterMediaReset else { return }
    scheduleRecovery(reason: healthReason, resetBudget: false)
  }

  private func activate(
    reason activationReason: String,
    generation: UInt,
    completion: ((Bool) -> Void)?
  ) {
    guard isCurrent(generation), !activeCall, !interruptionActive,
          !mediaServicesUnavailable, !awaitingUserAfterMediaReset else {
      completion?(false)
      return
    }
    cancelHealthTimer()
    setState(.recovering, reason: activationReason)
    driver.start { [weak self] started, failureReason in
      guard let self else { completion?(false); return }
      guard self.isCurrent(generation), self.wantsRunning else {
        completion?(false)
        return
      }
      guard self.recoveryIsAllowed else {
        self.setBlockedState()
        completion?(false)
        return
      }
      if started {
        self.retryCount = 0
        self.armHealthTimer()
        self.setState(.running, reason: nil)
        completion?(true)
      } else {
        self.scheduleRecovery(
          reason: failureReason ?? Reason.audioEngineFailed,
          resetBudget: false
        )
        completion?(false)
      }
    }
  }

  private func scheduleRecovery(reason recoveryReason: String, resetBudget: Bool) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard wantsRunning, !activeCall, !mediaServicesUnavailable,
          !interruptionActive, !awaitingUserAfterMediaReset else {
      if activeCall { setState(.interrupted, reason: Reason.callActive) }
      return
    }
    if resetBudget {
      retryCount = 0
      cancelRetry()
    }
    guard retryTask == nil else { return }
    guard retryCount < Self.maxRetryCount else {
      cancelHealthTimer()
      setState(.failed, reason: Reason.retryLimitExceeded)
      return
    }

    let index = retryCount
    retryCount += 1
    let delay = Self.retryDelays[min(index, Self.retryDelays.count - 1)]
    setState(.recovering, reason: recoveryReason)
    retryGeneration &+= 1
    let generation = retryGeneration
    let intent = intentGeneration
    retryTask = scheduler.schedule(after: delay, repeating: nil) { [weak self] in
      guard let self, self.retryGeneration == generation,
            self.isCurrent(intent), self.wantsRunning else { return }
      self.retryTask = nil
      self.activate(reason: recoveryReason, generation: intent, completion: nil)
    }
  }

  private func armHealthTimer() {
    cancelHealthTimer()
    healthTask = scheduler.schedule(
      after: Self.healthInterval,
      repeating: Self.healthInterval
    ) { [weak self] in
      self?.inspectHealth(reason: Reason.audioNotRunning, resetBudget: false)
    }
  }

  private func cancelRetry() {
    retryGeneration &+= 1
    retryTask?.cancel()
    retryTask = nil
  }

  private func cancelHealthTimer() {
    healthTask?.cancel()
    healthTask = nil
  }

  private func isCurrent(_ generation: UInt) -> Bool {
    generation == intentGeneration
  }

  private var recoveryIsAllowed: Bool {
    wantsRunning && !activeCall && !interruptionActive
      && !interruptionResumeDenied && !mediaServicesUnavailable
      && !awaitingUserAfterMediaReset
  }

  private func setBlockedState() {
    if activeCall {
      setState(.interrupted, reason: Reason.callActive)
    } else if mediaServicesUnavailable {
      setState(.interrupted, reason: Reason.mediaServicesLost)
    } else if awaitingUserAfterMediaReset {
      setState(.interrupted, reason: Reason.mediaServicesReset)
    } else if interruptionResumeDenied {
      setState(.interrupted, reason: Reason.resumeNotRequested)
    } else if interruptionActive {
      setState(.interrupted, reason: Reason.interruption)
    }
  }

  private func setState(_ newState: State, reason newReason: String?) {
    dispatchPrecondition(condition: .onQueue(.main))
    state = newState
    reason = newReason
  }

  private func statusSnapshot() -> [String: Any] {
    var value: [String: Any] = ["state": state.rawValue]
    if let reason { value["reason"] = reason }
    return value
  }

  private func uintValue(_ value: Any?) -> UInt? {
    if let value = value as? UInt { return value }
    if let value = value as? NSNumber { return value.uintValue }
    return nil
  }

  func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
    dispatchPrecondition(condition: .onQueue(.main))
    let wasActive = activeCall
    activeCall = callObserver.calls.contains { !$0.hasEnded }
    guard wantsRunning else { return }
    if activeCall {
      cancelRetry()
      cancelHealthTimer()
      driver.stop(deactivateSession: false) {}
      setState(.interrupted, reason: Reason.callActive)
    } else if wasActive {
      if interruptionResumeDenied {
        setState(.interrupted, reason: Reason.resumeNotRequested)
        return
      }
      interruptionActive = false
      if awaitingUserAfterMediaReset || mediaServicesUnavailable { return }
      inspectHealth(reason: Reason.callEnded, resetBudget: true)
    }
  }
}
