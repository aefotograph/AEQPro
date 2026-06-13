//
//  AEQProApp.swift
//  AEQ Pro — Advanced macOS Equalizer
//
//  Minimal modern UI • Real audio engine • 31-band EQ • FFT spectrum
//  Selectable input & output devices
//  Per-app routing: send Safari to your headset, Music to your speakers, etc.
//  (Per-app routing uses Core Audio process taps — requires macOS 14.4+)
//
//  created by aefotograph
//

import SwiftUI
import Combine
import AVFoundation
import AudioToolbox
import CoreAudio
import Accelerate
import AppKit

// MARK: - App Entry

@main
struct AEQProApp: App {
    var body: some Scene {
        WindowGroup {
            AEQProView()
        }
        .windowStyle(.hiddenTitleBar)
    }
}

// MARK: - Audio Devices (AirPods, speakers, mics, interfaces)

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
}

enum AudioDeviceList {

    static func inputDevices() -> [AudioDevice] {
        allDevices().filter { channelCount(device: $0.id, input: true) > 0 }
    }

    static func outputDevices() -> [AudioDevice] {
        allDevices().filter { channelCount(device: $0.id, input: false) > 0 }
    }

    static func defaultOutputDeviceUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr, deviceID != 0 else { return nil }

        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &uid) { ptr in
            AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, ptr)
        }
        return status == noErr ? (uid as String) : nil
    }

    private static func allDevices() -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }

        return ids.map { AudioDevice(id: $0, name: deviceName($0)) }
    }

    private static func deviceName(_ id: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &name) { ptr in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, ptr)
        }
        return status == noErr ? (name as String) : "Unknown Device"
    }

    private static func channelCount(device: AudioDeviceID, input: Bool) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size > 0 else { return 0 }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }

        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr
        else { return 0 }

        let list = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self)
        )
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

// MARK: - Audio Sources (processes actually producing sound right now)
// Apps like Safari and Chrome play sound through hidden helper processes,
// so we ask Core Audio directly: "who is making sound?"

struct AudioSource: Identifiable, Hashable {
    let id: String             // display name acts as the ID (groups helper processes)
    let name: String
    let objectIDs: [AudioObjectID]   // every Core Audio process behind this name
    let isPlaying: Bool
}

enum AudioSourceList {

    // Hidden helper processes mapped to the app you actually know
    private static let friendlyNames: [String: String] = [
        "com.apple.WebKit.GPU": "Safari (web media)",
        "com.apple.WebKit.WebContent": "Safari (web page)",
        "com.google.Chrome.helper": "Chrome (media)",
        "com.google.Chrome.helper.GPU": "Chrome (media)",
        "org.mozilla.firefox": "Firefox",
        "com.apple.Music": "Music",
        "com.apple.TV": "Apple TV",
        "com.spotify.client": "Spotify",
        "com.apple.QuickTimePlayerX": "QuickTime Player",
        "us.zoom.xos": "Zoom",
        "com.microsoft.teams2": "Microsoft Teams",
        "com.hnc.Discord": "Discord",
        "com.apple.FaceTime": "FaceTime"
    ]

    static func sources() -> [AudioSource] {
        var grouped: [String: (ids: [AudioObjectID], playing: Bool)] = [:]

        for object in processObjects() {
            let bundleID = stringProperty(object, kAudioProcessPropertyBundleID) ?? ""
            let pid = pidProperty(object)
            let playing = boolProperty(object, kAudioProcessPropertyIsRunningOutput)

            var name = friendlyNames[bundleID]
            // Helper processes (WebKit, Chrome Helper…) → name them after their owner app
            if name == nil, bundleID.localizedCaseInsensitiveContains("webkit") {
                name = "Safari (web media)"
            }
            if name == nil, bundleID.localizedCaseInsensitiveContains("chrome") {
                name = "Chrome (media)"
            }
            if name == nil, let pid,
               let app = NSRunningApplication(processIdentifier: pid),
               let appName = app.localizedName {
                name = appName
            }
            if name == nil, !bundleID.isEmpty {
                name = bundleID.components(separatedBy: ".").last?.capitalized
            }
            guard let finalName = name, !finalName.isEmpty else { continue }

            var entry = grouped[finalName] ?? ([], false)
            entry.ids.append(object)
            entry.playing = entry.playing || playing
            grouped[finalName] = entry
        }

        return grouped.map { name, entry in
            AudioSource(id: name, name: name,
                        objectIDs: entry.ids, isPlaying: entry.playing)
        }
        .sorted {
            if $0.isPlaying != $1.isPlaying { return $0.isPlaying }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private static func processObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }
        return ids
    }

    private static func stringProperty(_ object: AudioObjectID,
                                       _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, ptr)
        }
        return status == noErr ? (value as String) : nil
    }

    private static func pidProperty(_ object: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &pid)
        return status == noErr ? pid : nil
    }

    private static func boolProperty(_ object: AudioObjectID,
                                     _ selector: AudioObjectPropertySelector) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        return status == noErr && value != 0
    }
}

// MARK: - EQ Band Model

struct EQBand: Identifiable {
    let id = UUID()
    let frequency: Float
    var gain: Float

    var label: String {
        if frequency >= 1000 {
            let k = frequency / 1000
            return k == k.rounded() ? "\(Int(k))k" : String(format: "%.1fk", k)
        }
        return "\(Int(frequency))"
    }

    static let frequencies: [Float] = [
        20, 25, 31.5, 40, 50, 63, 80, 100,
        125, 160, 200, 250, 315, 400, 500, 630,
        800, 1000, 1250, 1600, 2000, 2500, 3150,
        4000, 5000, 6300, 8000, 10000, 12500,
        16000, 20000
    ]

    static var defaultBands: [EQBand] {
        frequencies.map { EQBand(frequency: $0, gain: 0) }
    }
}

// MARK: - Per-App Route
// Taps one app's audio, mutes it at its normal output,
// and replays it (EQ'd) on the output device you chose.

final class AppRoute: Identifiable, ObservableObject {
    let id = UUID()
    let appName: String
    let processObjects: [AudioObjectID]
    let outputDeviceID: AudioDeviceID
    let outputDeviceName: String

    @Published var statusText = "Starting…"
    @Published var isActive = false

    private var tapID = AudioObjectID(0)
    private var aggregateID = AudioObjectID(0)
    private var engine: AVAudioEngine?
    private var eq = AVAudioUnitEQ(numberOfBands: 31)

    init(appName: String, processObjects: [AudioObjectID],
         outputDeviceID: AudioDeviceID, outputDeviceName: String) {
        self.appName = appName
        self.processObjects = processObjects
        self.outputDeviceID = outputDeviceID
        self.outputDeviceName = outputDeviceName
    }

    func start(bands: [EQBand], preampDB: Float, bypass: Bool) {
        // 1. Create the process tap (captures only this app, mutes its normal output)
        let description = CATapDescription(stereoMixdownOfProcesses: processObjects)
        description.muteBehavior = .mutedWhenTapped
        description.name = "AEQ Tap — \(appName)"
        description.isPrivate = true

        var newTapID = AudioObjectID(0)
        var err = AudioHardwareCreateProcessTap(description, &newTapID)
        guard err == noErr, newTapID != 0 else {
            statusText = "Tap failed (error \(err)). Check System Audio Recording permission."
            isActive = false
            return
        }
        tapID = newTapID

        // Ask the tap itself for its UID — the reliable way to link it
        var tapUID = description.uuid.uuidString
        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uidValue: CFString = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        let uidStatus = withUnsafeMutablePointer(to: &uidValue) { ptr in
            AudioObjectGetPropertyData(tapID, &uidAddress, 0, nil, &uidSize, ptr)
        }
        if uidStatus == noErr { tapUID = uidValue as String }

        // 2. Wrap the tap in a private aggregate device (anchored to a real device for clock)
        guard let clockUID = AudioDeviceList.defaultOutputDeviceUID() else {
            statusText = "Could not find the system output device."
            cleanupTap()
            isActive = false
            return
        }
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "AEQ Route \(appName)",
            kAudioAggregateDeviceUIDKey as String: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceMainSubDeviceKey as String: clockUID,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [kAudioSubDeviceUIDKey as String: clockUID]
            ],
            kAudioAggregateDeviceTapListKey as String: [
                [kAudioSubTapUIDKey as String: tapUID,
                 kAudioSubTapDriftCompensationKey as String: true]
            ]
        ]
        var newAggregateID = AudioObjectID(0)
        err = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary, &newAggregateID
        )
        guard err == noErr, newAggregateID != 0 else {
            statusText = "Could not create routing device (error \(err))."
            cleanupTap()
            isActive = false
            return
        }
        aggregateID = newAggregateID

        // 3. Engine: tap (as input) → EQ → chosen output device
        let newEngine = AVAudioEngine()
        setDevice(aggregateID, on: newEngine.inputNode.audioUnit)
        setDevice(outputDeviceID, on: newEngine.outputNode.audioUnit)

        configureEQ(bands: bands, preampDB: preampDB, bypass: bypass)

        newEngine.attach(eq)
        let format = newEngine.inputNode.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            statusText = "No audio coming from \(appName) yet — press play, then retry."
            cleanupAggregate()
            cleanupTap()
            isActive = false
            return
        }
        newEngine.connect(newEngine.inputNode, to: eq, format: format)
        newEngine.connect(eq, to: newEngine.mainMixerNode, format: format)

        do {
            newEngine.prepare()
            try newEngine.start()
            engine = newEngine
            isActive = true
            statusText = "\(appName) → \(outputDeviceName)"
        } catch {
            statusText = "Engine failed: \(error.localizedDescription)"
            cleanupAggregate()
            cleanupTap()
            isActive = false
        }
    }

    func updateEQ(bands: [EQBand], preampDB: Float, bypass: Bool) {
        configureEQ(bands: bands, preampDB: preampDB, bypass: bypass)
    }

    func stop() {
        engine?.stop()
        engine = nil
        cleanupAggregate()
        cleanupTap()
        isActive = false
        statusText = "Stopped"
    }

    private func configureEQ(bands: [EQBand], preampDB: Float, bypass: Bool) {
        for (i, band) in bands.enumerated() where i < 31 {
            let p = eq.bands[i]
            p.filterType = .parametric
            p.frequency = band.frequency
            p.bandwidth = 0.33
            p.gain = band.gain
            p.bypass = false
        }
        eq.globalGain = preampDB
        eq.bypass = bypass
    }

    private func setDevice(_ deviceID: AudioDeviceID, on audioUnit: AudioUnit?) {
        guard deviceID != 0, let audioUnit else { return }
        var id = deviceID
        AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
    }

    private func cleanupTap() {
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
        }
    }

    private func cleanupAggregate() {
        if aggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = 0
        }
    }

    deinit {
        stop()
    }
}

// MARK: - System Audio Permission
// macOS never shows the system-audio popup by itself — the app must explicitly
// ask for "kTCCServiceAudioCapture". (Same approach as the AudioCap project.)

enum SystemAudioPermission {
    enum Status { case unknown, denied, authorized }

    private typealias PreflightFunc = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFunc =
        @convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void

    private static let handle = dlopen(
        "/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW
    )

    private static let preflightFn: PreflightFunc? = {
        guard let handle, let sym = dlsym(handle, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(sym, to: PreflightFunc.self)
    }()

    private static let requestFn: RequestFunc? = {
        guard let handle, let sym = dlsym(handle, "TCCAccessRequest") else { return nil }
        return unsafeBitCast(sym, to: RequestFunc.self)
    }()

    static func currentStatus() -> Status {
        guard let preflightFn else { return .unknown }
        switch preflightFn("kTCCServiceAudioCapture" as CFString, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .unknown
        }
    }

    static func request(_ completion: @escaping (Bool) -> Void) {
        guard let requestFn else {
            completion(false)
            return
        }
        requestFn("kTCCServiceAudioCapture" as CFString, nil) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }
}

// MARK: - Ring Buffer (small memory tube between capture and playback)

final class StereoRingBuffer {
    private var left: [Float]
    private var right: [Float]
    private var writeIndex = 0
    private var readIndex = 0
    private let capacity: Int
    private let lock = NSLock()

    init(capacity: Int = 65536) {
        self.capacity = capacity
        left = [Float](repeating: 0, count: capacity)
        right = [Float](repeating: 0, count: capacity)
    }

    private var framesWritten = 0
    private var peakLevel: Float = 0

    func captureSnapshot() -> (frames: Int, peak: Float) {
        lock.lock()
        let result = (framesWritten, peakLevel)
        framesWritten = 0
        peakLevel = 0
        lock.unlock()
        return result
    }

    func write(left l: UnsafePointer<Float>, right r: UnsafePointer<Float>, count: Int) {
        lock.lock()
        framesWritten += count
        for i in 0..<count where abs(l[i]) > peakLevel { peakLevel = abs(l[i]) }
        for i in 0..<count {
            left[writeIndex] = l[i]
            right[writeIndex] = r[i]
            writeIndex = (writeIndex + 1) % capacity
            if writeIndex == readIndex {
                readIndex = (readIndex + 1) % capacity
            }
        }
        lock.unlock()
    }

    func read(intoLeft l: UnsafeMutablePointer<Float>,
              right r: UnsafeMutablePointer<Float>, count: Int) {
        lock.lock()
        for i in 0..<count {
            if readIndex == writeIndex {
                l[i] = 0
                r[i] = 0
            } else {
                l[i] = left[readIndex]
                r[i] = right[readIndex]
                readIndex = (readIndex + 1) % capacity
            }
        }
        lock.unlock()
    }
}

// MARK: - Main Audio Engine (system-wide EQ)

final class AEQEngine: ObservableObject {

    // Controls
    @Published var isEnabled = true {
        didSet {
            if isEnabled {
                restartEngine()
                for route in Array(routes) { retryRoute(route) }
            } else {
                powerDown()
            }
        }
    }
    @Published var preampDB: Float = 0 { didSet { eq.globalGain = preampDB; pushEQToRoutes() } }
    @Published var amplifierDB: Float = 0 { didSet { updateLimiter() } }
    @Published var compressorAmount: Float = 0.35 { didSet { updateCompressor() } }
    @Published var outputGain: Float = 1.0 { didSet { engine.mainMixerNode.outputVolume = outputGain } }
    @Published var autoGainProtection = true { didSet { updateBypass() } }
    @Published var bands: [EQBand] = EQBand.defaultBands {
        didSet { updateEQGains(); pushEQToRoutes() }
    }
    @Published var activePreset = "Flat"

    // Devices
    @Published var outputDevices: [AudioDevice] = []
    @Published var selectedOutputID: AudioDeviceID = 0 {
        didSet { if oldValue != selectedOutputID { restartEngine() } }
    }

    // System-wide tap (captures everything the Mac plays)
    private var systemTapID = AudioObjectID(0)
    private var systemAggregateID = AudioObjectID(0)
    private var ioProcID: AudioDeviceIOProcID?
    private let ringBuffer = StereoRingBuffer()
    private var sourceNode: AVAudioSourceNode?

    // Per-app routes
    @Published var routes: [AppRoute] = []
    @Published var audioSources: [AudioSource] = []

    // Status
    @Published var spectrum: [Float] = Array(repeating: 0.02, count: 64)
    @Published var isClipping = false
    @Published var isRunning = false
    @Published var statusMessage = "Starting…"
    @Published var captureInfo = "—"

    // Audio graph
    private var engine = AVAudioEngine()
    private var eq = AVAudioUnitEQ(numberOfBands: 31)
    private var compressor: AVAudioUnitEffect
    private var limiter: AVAudioUnitEffect

    private var sourceTimer: Timer?
    private let fftSize = 2048
    private let log2n: vDSP_Length = 11
    private var fftSetup: FFTSetup?
    private var clipResetWorkItem: DispatchWorkItem?

    init() {
        let compDesc = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_DynamicsProcessor,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0
        )
        compressor = AVAudioUnitEffect(audioComponentDescription: compDesc)

        let limDesc = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_PeakLimiter,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0
        )
        limiter = AVAudioUnitEffect(audioComponentDescription: limDesc)

        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))

        refreshDevices()
        refreshSources()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }

            // Self-check: without this Info.plist text, macOS auto-denies silently
            if Bundle.main.object(forInfoDictionaryKey: "NSAudioCaptureUsageDescription") == nil {
                self.statusMessage = "SETUP PROBLEM: the NSAudioCaptureUsageDescription key is missing from the app — add it in the target's Info tab."
                return
            }

            switch SystemAudioPermission.currentStatus() {
            case .authorized:
                self.restartEngine()
            case .denied:
                self.statusMessage = "Access denied — enable AEQPro in System Settings → Privacy & Security → Screen & System Audio Recording, then press Restart."
            case .unknown:
                self.statusMessage = "Asking macOS for system-audio access…"
                SystemAudioPermission.request { granted in
                    if granted {
                        self.restartEngine()
                    } else {
                        self.statusMessage = "Access denied — enable AEQPro in System Settings → Privacy & Security → Screen & System Audio Recording, then press Restart."
                    }
                }
            }
        }

        // Keep the sound-source list fresh + report whether audio is arriving
        sourceTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.refreshSources()
            let snap = self.ringBuffer.captureSnapshot()
            if !self.isEnabled {
                self.captureInfo = "—"
            } else if !self.isRunning {
                self.captureInfo = "engine off"
            } else if snap.frames == 0 {
                self.captureInfo = "no signal"
            } else if snap.peak < 0.001 {
                self.captureInfo = "silence"
            } else {
                self.captureInfo = "capturing"
            }
        }

        // Safety net: always release the mute when the app quits
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.routes.forEach { $0.stop() }
            self.engine.stop()
            self.tearDownSystemTap()
        }
    }

    deinit {
        sourceTimer?.invalidate()
        routes.forEach { $0.stop() }
        engine.stop()
        tearDownSystemTap()
        if let fftSetup { vDSP_destroy_fftsetup(fftSetup) }
    }

    // MARK: Device + app lists

    func refreshDevices() {
        outputDevices = AudioDeviceList.outputDevices()
    }

    func refreshSources() {
        audioSources = AudioSourceList.sources()
    }

    private func setDevice(_ deviceID: AudioDeviceID, on audioUnit: AudioUnit?) {
        guard deviceID != 0, let audioUnit else { return }
        var id = deviceID
        AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
    }

    // MARK: Per-app routing

    func addRoute(sourceID: String, outputID: AudioDeviceID) {
        guard let source = audioSources.first(where: { $0.id == sourceID }) else { return }
        let outputName = outputDevices.first(where: { $0.id == outputID })?.name
            ?? "System Default"

        // One route per source — replace an old one for the same source
        if let existing = routes.first(where: { $0.appName == source.name }) {
            existing.stop()
            routes.removeAll { $0.appName == source.name }
        }

        let route = AppRoute(appName: source.name, processObjects: source.objectIDs,
                             outputDeviceID: outputID, outputDeviceName: outputName)
        route.start(bands: bands, preampDB: preampDB, bypass: !isEnabled)
        routes.append(route)
        restartEngine()   // carve the routed app out of the main EQ stream
    }

    func retryRoute(_ route: AppRoute) {
        route.stop()
        refreshSources()
        // If the app restarted, its process IDs changed — rebuild with fresh ones
        if let fresh = audioSources.first(where: { $0.name == route.appName }) {
            let rebuilt = AppRoute(appName: fresh.name, processObjects: fresh.objectIDs,
                                   outputDeviceID: route.outputDeviceID,
                                   outputDeviceName: route.outputDeviceName)
            rebuilt.start(bands: bands, preampDB: preampDB, bypass: !isEnabled)
            routes.removeAll { $0.id == route.id }
            routes.append(rebuilt)
        } else {
            route.start(bands: bands, preampDB: preampDB, bypass: !isEnabled)
        }
    }

    func removeRoute(_ route: AppRoute) {
        route.stop()
        routes.removeAll { $0.id == route.id }
        restartEngine()
    }

    private func pushEQToRoutes() {
        for route in routes {
            route.updateEQ(bands: bands, preampDB: preampDB, bypass: !isEnabled)
        }
    }

    // MARK: System-wide EQ chain
    // Taps everything the Mac plays, mutes the original,
    // and replays it through the EQ to your chosen output.

    private func ownProcessObject() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var object = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var pid: pid_t = getpid()
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object
        )
        return (status == noErr && object != 0) ? object : nil
    }

    private func tearDownSystemTap() {
        if let ioProcID, systemAggregateID != 0 {
            AudioDeviceStop(systemAggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(systemAggregateID, ioProcID)
        }
        ioProcID = nil
        if systemAggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(systemAggregateID)
            systemAggregateID = 0
        }
        if systemTapID != 0 {
            AudioHardwareDestroyProcessTap(systemTapID)
            systemTapID = 0
        }
    }

    func powerDown() {
        routes.forEach { $0.stop() }
        engine.stop()
        engine.mainMixerNode.removeTap(onBus: 0)
        tearDownSystemTap()
        isRunning = false
        statusMessage = "Offline"
        captureInfo = "—"
    }

    func restartEngine() {
        guard isEnabled else {
            powerDown()
            return
        }
        engine.stop()
        engine.mainMixerNode.removeTap(onBus: 0)
        engine = AVAudioEngine()
        sourceNode = nil
        tearDownSystemTap()

        // Never capture ourselves (instant feedback loop),
        // and skip apps that already have their own route below.
        var excluded: [AudioObjectID] = []
        if let me = ownProcessObject() { excluded.append(me) }
        for route in routes where route.isActive {
            excluded.append(contentsOf: route.processObjects)
        }

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        description.muteBehavior = .mutedWhenTapped
        description.name = "AEQ System Tap"
        description.isPrivate = true

        var newTapID = AudioObjectID(0)
        var err = AudioHardwareCreateProcessTap(description, &newTapID)
        guard err == noErr, newTapID != 0 else {
            isRunning = false
            statusMessage = "System audio access needed — allow AEQ Pro under System Settings → Privacy & Security → Screen & System Audio Recording, then press Restart."
            return
        }
        systemTapID = newTapID

        var tapUID = description.uuid.uuidString
        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uidValue: CFString = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        let uidStatus = withUnsafeMutablePointer(to: &uidValue) { ptr in
            AudioObjectGetPropertyData(systemTapID, &uidAddress, 0, nil, &uidSize, ptr)
        }
        if uidStatus == noErr { tapUID = uidValue as String }

        guard let clockUID = AudioDeviceList.defaultOutputDeviceUID() else {
            isRunning = false
            statusMessage = "Could not find the system output device."
            tearDownSystemTap()
            return
        }
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "AEQ System",
            kAudioAggregateDeviceUIDKey as String: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceMainSubDeviceKey as String: clockUID,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [kAudioSubDeviceUIDKey as String: clockUID]
            ],
            kAudioAggregateDeviceTapListKey as String: [
                [kAudioSubTapUIDKey as String: tapUID,
                 kAudioSubTapDriftCompensationKey as String: true]
            ]
        ]
        var newAggregateID = AudioObjectID(0)
        err = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary, &newAggregateID
        )
        guard err == noErr, newAggregateID != 0 else {
            isRunning = false
            statusMessage = "Could not create the system capture device (error \(err))."
            tearDownSystemTap()
            return
        }
        systemAggregateID = newAggregateID

        // Read what format the tap delivers (sample rate etc.)
        var tapASBD = AudioStreamBasicDescription()
        var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(systemTapID, &formatAddress, 0, nil, &asbdSize, &tapASBD)
        let sampleRate = tapASBD.mSampleRate > 0 ? tapASBD.mSampleRate : 48000

        // Low-level reader: copies captured system audio into the ring buffer
        let ring = ringBuffer
        var newProcID: AudioDeviceIOProcID?
        var procErr = AudioDeviceCreateIOProcIDWithBlock(
            &newProcID, systemAggregateID, nil
        ) { _, inInputData, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inInputData)
            )
            guard buffers.count > 0 else { return }
            if buffers.count >= 2,
               let lRaw = buffers[0].mData, let rRaw = buffers[1].mData {
                let frames = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size
                ring.write(left: lRaw.assumingMemoryBound(to: Float.self),
                           right: rRaw.assumingMemoryBound(to: Float.self),
                           count: frames)
            } else if let raw = buffers[0].mData {
                let channels = max(1, Int(buffers[0].mNumberChannels))
                let totalFloats = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size
                let frames = totalFloats / channels
                let data = raw.assumingMemoryBound(to: Float.self)
                var l = [Float](repeating: 0, count: frames)
                var r = [Float](repeating: 0, count: frames)
                for f in 0..<frames {
                    l[f] = data[f * channels]
                    r[f] = channels > 1 ? data[f * channels + 1] : data[f * channels]
                }
                l.withUnsafeBufferPointer { lp in
                    r.withUnsafeBufferPointer { rp in
                        ring.write(left: lp.baseAddress!, right: rp.baseAddress!,
                                   count: frames)
                    }
                }
            }
        }
        guard procErr == noErr, let startedProcID = newProcID else {
            statusMessage = "Could not read system audio (error \(procErr))."
            isRunning = false
            tearDownSystemTap()
            return
        }
        ioProcID = startedProcID
        procErr = AudioDeviceStart(systemAggregateID, startedProcID)
        guard procErr == noErr else {
            statusMessage = "Could not start system capture (error \(procErr))."
            isRunning = false
            tearDownSystemTap()
            return
        }

        // Playback side: ring buffer → EQ → compressor → limiter → chosen output
        setDevice(selectedOutputID, on: engine.outputNode.audioUnit)

        configureEQ()
        updateCompressor()
        updateLimiter()
        updateBypass()

        guard let playbackFormat = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate, channels: 2
        ) else {
            statusMessage = "Could not create the playback format."
            isRunning = false
            tearDownSystemTap()
            return
        }

        let newSourceNode = AVAudioSourceNode(format: playbackFormat) {
            _, _, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard buffers.count >= 2,
                  let lRaw = buffers[0].mData, let rRaw = buffers[1].mData else {
                return noErr
            }
            ring.read(intoLeft: lRaw.assumingMemoryBound(to: Float.self),
                      right: rRaw.assumingMemoryBound(to: Float.self),
                      count: Int(frameCount))
            return noErr
        }
        sourceNode = newSourceNode

        engine.attach(newSourceNode)
        engine.attach(eq)
        engine.attach(compressor)
        engine.attach(limiter)

        engine.connect(newSourceNode, to: eq, format: playbackFormat)
        engine.connect(eq, to: compressor, format: playbackFormat)
        engine.connect(compressor, to: limiter, format: playbackFormat)
        engine.connect(limiter, to: engine.mainMixerNode, format: playbackFormat)

        let inputFormat = playbackFormat

        engine.mainMixerNode.outputVolume = outputGain
        installSpectrumTap()

        do {
            engine.prepare()
            try engine.start()
            isRunning = true
            statusMessage = "EQ active on all Mac audio • \(Int(inputFormat.sampleRate)) Hz"
        } catch {
            isRunning = false
            statusMessage = "Engine error: \(error.localizedDescription)"
            tearDownSystemTap()
        }
    }

    private func configureEQ() {
        for (i, band) in bands.enumerated() where i < 31 {
            let p = eq.bands[i]
            p.filterType = .parametric
            p.frequency = band.frequency
            p.bandwidth = 0.33
            p.gain = band.gain
            p.bypass = false
        }
        eq.globalGain = preampDB
    }

    private func updateEQGains() {
        for (i, band) in bands.enumerated() where i < 31 {
            eq.bands[i].gain = band.gain
        }
    }

    private func updateCompressor() {
        let threshold = -2 - compressorAmount * 28
        AudioUnitSetParameter(compressor.audioUnit, kDynamicsProcessorParam_Threshold,
                              kAudioUnitScope_Global, 0, threshold, 0)
        AudioUnitSetParameter(compressor.audioUnit, kDynamicsProcessorParam_AttackTime,
                              kAudioUnitScope_Global, 0, 0.005, 0)
        AudioUnitSetParameter(compressor.audioUnit, kDynamicsProcessorParam_ReleaseTime,
                              kAudioUnitScope_Global, 0, 0.1, 0)
    }

    private func updateLimiter() {
        AudioUnitSetParameter(limiter.audioUnit, kLimiterParam_PreGain,
                              kAudioUnitScope_Global, 0, amplifierDB, 0)
        AudioUnitSetParameter(limiter.audioUnit, kLimiterParam_AttackTime,
                              kAudioUnitScope_Global, 0, 0.002, 0)
        AudioUnitSetParameter(limiter.audioUnit, kLimiterParam_DecayTime,
                              kAudioUnitScope_Global, 0, 0.05, 0)
    }

    private func updateBypass() {
        eq.bypass = !isEnabled
        compressor.bypass = !isEnabled
        limiter.bypass = !(isEnabled && autoGainProtection)
    }

    // MARK: Spectrum

    private func installSpectrumTap() {
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        engine.mainMixerNode.installTap(onBus: 0,
                                        bufferSize: AVAudioFrameCount(fftSize),
                                        format: format) { [weak self] buffer, _ in
            self?.analyze(buffer)
        }
    }

    private func analyze(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0],
              Int(buffer.frameLength) >= fftSize,
              let fftSetup else { return }

        let sampleRate = Float(buffer.format.sampleRate)

        var peak: Float = 0
        vDSP_maxmgv(channelData, 1, &peak, vDSP_Length(buffer.frameLength))

        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(channelData, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        let halfSize = fftSize / 2
        var real = [Float](repeating: 0, count: halfSize)
        var imag = [Float](repeating: 0, count: halfSize)
        var magnitudes = [Float](repeating: 0, count: halfSize)

        real.withUnsafeMutableBufferPointer { realPtr in
            imag.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!,
                                            imagp: imagPtr.baseAddress!)
                windowed.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!,
                              2, &split, 1, vDSP_Length(halfSize))
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(halfSize))
            }
        }

        var bars = [Float](repeating: 0, count: 64)
        for b in 0..<64 {
            let f0 = 20 * pow(1000, Float(b) / 64)
            let f1 = 20 * pow(1000, Float(b + 1) / 64)
            var start = max(1, Int(f0 * Float(fftSize) / sampleRate))
            var end = max(start + 1, Int(f1 * Float(fftSize) / sampleRate))
            start = min(start, halfSize - 1)
            end = min(end, halfSize)
            var maxMag: Float = 0
            for i in start..<end { maxMag = max(maxMag, magnitudes[i]) }
            let db = 10 * log10f(maxMag + 1e-12)
            bars[b] = max(0, min(1, (db + 70) / 70))
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for i in 0..<64 {
                self.spectrum[i] = max(self.spectrum[i] * 0.72, bars[i])
            }
            if peak > 0.98 {
                self.isClipping = true
                self.clipResetWorkItem?.cancel()
                let work = DispatchWorkItem { self.isClipping = false }
                self.clipResetWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
            }
        }
    }

    // MARK: Reset + presets

    func reset() {
        preampDB = 0
        amplifierDB = 0
        compressorAmount = 0.35
        outputGain = 1
        autoGainProtection = true
        bands = EQBand.defaultBands
        activePreset = "Flat"
    }

    static let presetOrder = [
        "Flat", "Baila", "Bass", "Rock", "Pop", "Hip-Hop", "EDM",
        "Jazz", "Classical", "Acoustic", "R&B", "Latin",
        "Vocal", "Cinema", "Air"
    ]

    // 31 gains per preset, one per band (20 Hz → 20 kHz), tuned per genre.
    // "Baila" is tuned for Sri Lankan baila: deep dance bass, conga/bongo punch,
    // cleared low-mids, forward vocals, brass bite and bright percussion.
    static let presetGains: [String: [Float]] = [
        "Bass": [6, 6, 5.5, 5.5, 5.5, 5.5, 5, 5, 4, 3, 2, 1, 0.5, 0.5, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        "Rock": [4, 4, 4, 4, 4.5, 4.5, 4.5, 3.5, 3, 2, 1, 0, -1, -2, -1.5, -1.5, -1, -0.5, 0, 0.5, 1, 1.5, 2.5, 3, 3.5, 3.5, 4, 4, 4, 3.5, 3.5],
        "Pop": [1, 1, 1.5, 2, 2, 2, 2.5, 2.5, 2, 2, 1.5, 1, 0.5, 0, 0, 0.5, 1, 1, 1.5, 2, 2.5, 3, 3, 2.5, 2.5, 2.5, 2, 2, 2, 1.5, 1.5],
        "Hip-Hop": [5.5, 5.5, 5.5, 6, 6, 6, 5.5, 4.5, 4, 3, 2, 1, 0, -0.5, -1, -0.5, 0, 0, 0.5, 1, 1.5, 2, 2.5, 2.5, 2.5, 3, 3, 3, 3, 2.5, 2.5],
        "EDM": [5.5, 5.5, 5.5, 5, 5, 5, 4, 3.5, 2.5, 1.5, 1, 0.5, -0.5, -1, -1, -0.5, 0, 0, 0.5, 0.5, 1, 1, 1.5, 2, 2.5, 3, 3.5, 3.5, 4, 4, 4],
        "Jazz": [3, 3, 3, 3, 3.5, 3.5, 3.5, 3, 2.5, 1.5, 1, 1, 0.5, 0.5, 0, 0, 0, 0, 0.5, 0.5, 0.5, 1, 1, 1.5, 2, 2, 2.5, 2.5, 2.5, 2, 2],
        "Classical": [2.5, 2.5, 2.5, 2, 2, 2, 2, 1.5, 1.5, 1, 0.5, 0.5, 0, 0, 0, 0, 0, 0, 0, -0.5, -0.5, -1, -1, 0, 0.5, 1, 2, 2.5, 2.5, 3, 3],
        "Acoustic": [2, 2, 2.5, 2.5, 3, 3, 3.5, 3.5, 3, 2.5, 2, 1.5, 1, 1, 1, 0.5, 1, 1, 1.5, 1.5, 2, 2, 2, 2.5, 2.5, 2.5, 3, 3, 3, 2.5, 2.5],
        "R&B": [5, 5, 5, 5, 5, 5, 5, 4.5, 3.5, 2.5, 2, 1, 0, -1, -0.5, -0.5, 0, 0.5, 1, 1.5, 1.5, 2, 2.5, 2.5, 2, 2, 2.5, 2.5, 2.5, 2, 2],
        "Latin": [3.5, 3.5, 3.5, 4, 4, 4, 4, 3.5, 3, 2.5, 2, 1.5, 1, 0.5, 0, 0.5, 0.5, 1, 1, 1.5, 2, 2, 2.5, 3, 3, 3.5, 3, 3, 3, 2.5, 2.5],
        "Baila": [4.5, 4.5, 5, 5, 5.5, 5.5, 5, 5, 4.5, 3.5, 2, 0, -1.5, -2, -2, -1, 0, 1, 2, 3, 3, 3.5, 3.5, 4, 4, 4, 4, 4, 4.5, 3.5, 3],
        "Vocal": [-1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -0.5, 0, 0, 1, 2, 3, 3, 3.5, 4, 4, 3.5, 3, 2, 1, 0.5, 0, 0, 0, 0],
        "Cinema": [5, 5, 5, 5, 5, 5, 5, 5, 4, 3, 2, 1, 0, 0, 0, 0, 0, 0, 0, 0.5, 0.5, 0.5, 1, 1, 2, 3, 4, 4, 4, 4, 4],
        "Air": [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1.5, 3, 4.5, 6, 6, 6]
    ]

    func applyPreset(_ name: String) {
        activePreset = name
        var newBands = EQBand.defaultBands
        if let gains = Self.presetGains[name] {
            for i in newBands.indices where i < gains.count {
                newBands[i].gain = gains[i]
            }
        }
        bands = newBands
    }
}

// MARK: - Theme

enum Theme {
    static let accent = Color(red: 0.48, green: 0.42, blue: 0.95)
    static let accentSoft = Color(red: 0.48, green: 0.42, blue: 0.95).opacity(0.18)
    static let blue = Color(red: 0.35, green: 0.55, blue: 1.0)
    static let page = Color(red: 0.043, green: 0.043, blue: 0.06)
    static let card = Color(red: 0.075, green: 0.075, blue: 0.095)
    static let border = Color.white.opacity(0.07)
    static let text = Color.white
    static let muted = Color.white.opacity(0.55)
    static let faint = Color.white.opacity(0.32)
}

// MARK: - Main View

struct AEQProView: View {
    @StateObject private var engine = AEQEngine()
    @State private var routeSourceID: String = ""
    @State private var routeOutputID: AudioDeviceID = 0
    @State private var quip: String = AEQQuips.random()

    private let quipTimer = Timer.publish(every: 18, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Theme.page.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 14) {
                    headerCard
                    outputCard
                    eqCard
                    HStack(alignment: .top, spacing: 14) {
                        masterCard
                        spectrumCard
                    }
                    routingCard
                    quipFooter
                }
                .padding(20)
                .frame(maxWidth: 980)
                .frame(maxWidth: .infinity)
            }

            Text("aefotograph \u{1F1F1}\u{1F1F0}")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Theme.faint)
                .padding(10)
        }
        .preferredColorScheme(.dark)
        .frame(minWidth: 820, minHeight: 860)
    }

    // MARK: Header

    private var headerCard: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.accentSoft)
                .frame(width: 38, height: 38)
                .overlay(
                    Image(systemName: "waveform")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Theme.accent)
                )
            Text("AEQ Pro")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.text)
            Text(engine.statusMessage)
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
            HStack(spacing: 5) {
                Circle()
                    .fill(engine.captureInfo == "capturing" ? Color.green : Theme.faint)
                    .frame(width: 5, height: 5)
                Text(engine.captureInfo)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
            }

            Spacer()

            if engine.isClipping {
                Text("CLIP")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.red, in: Capsule())
            }

            HStack(spacing: 6) {
                Circle()
                    .fill(engine.isEnabled
                          ? (engine.isRunning ? Color.green : Color.orange)
                          : Theme.faint)
                    .frame(width: 7, height: 7)
                Text(engine.isEnabled ? (engine.isRunning ? "Live" : "Idle") : "Offline")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.text)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Theme.card, in: Capsule())
            .overlay(Capsule().stroke(Theme.border, lineWidth: 1))

            Toggle("", isOn: $engine.isEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(Theme.accent)
        }
        .cardStyle()
    }

    // MARK: Output

    private var outputCard: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("OUTPUT")
                HStack(spacing: 8) {
                    Image(systemName: "speaker.wave.2")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.muted)
                    Text("All Mac audio")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.text)
                }
            }
            Spacer()
            VStack(alignment: .leading, spacing: 8) {
                Text("Device")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                Picker("", selection: $engine.selectedOutputID) {
                    Text("System Default").tag(AudioDeviceID(0))
                    ForEach(engine.outputDevices) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .labelsHidden()
                .frame(width: 240)
            }
            Button {
                engine.refreshDevices()
                engine.refreshSources()
                if SystemAudioPermission.currentStatus() == .authorized {
                    engine.restartEngine()
                } else {
                    SystemAudioPermission.request { granted in
                        if granted { engine.restartEngine() }
                    }
                }
            } label: {
                Label("Restart", systemImage: "arrow.clockwise")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
        }
        .cardStyle()
    }

    // MARK: Equalizer

    private var eqCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                sectionTitle("EQUALIZER")
                Spacer()
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                ForEach(AEQEngine.presetOrder, id: \.self) { name in
                    Button {
                        engine.applyPreset(name)
                    } label: {
                        Text(name == "Baila" ? "Baila \u{1F1F1}\u{1F1F0}" : name)
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(
                                engine.activePreset == name
                                ? Theme.accentSoft : Color.white.opacity(0.04),
                                in: RoundedRectangle(cornerRadius: 9)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 9).stroke(
                                    engine.activePreset == name
                                    ? Theme.accent.opacity(0.6) : Theme.border,
                                    lineWidth: 1
                                )
                            )
                            .foregroundStyle(
                                engine.activePreset == name ? Theme.accent : Theme.muted
                            )
                    }
                    .buttonStyle(.plain)
                }
                }
            }

            EQGraphView(bands: $engine.bands)
                .frame(height: 240)
        }
        .cardStyle()
    }

    // MARK: Master

    private var masterCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                sectionTitle("MASTER")
                Spacer()
                Button("Reset") { engine.reset() }
                    .font(.system(size: 12, weight: .medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
            }

            masterSlider("Preamplifier", value: $engine.preampDB, range: -24...24, format: "%.0f dB")
            masterSlider("Amplifier", value: $engine.amplifierDB, range: 0...18, format: "%.0f dB")
            masterSlider("Compressor", value: $engine.compressorAmount, range: 0...1, format: "%.2f")
            masterSlider("Output", value: $engine.outputGain, range: 0...1.5, format: "%.2f")

            Toggle("Auto gain protection", isOn: $engine.autoGainProtection)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                .tint(Theme.accent)
        }
        .cardStyle()
        .frame(maxWidth: .infinity)
    }

    private func masterSlider(_ title: String, value: Binding<Float>,
                              range: ClosedRange<Float>, format: String) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                .frame(width: 92, alignment: .leading)
            Slider(value: value, in: range)
                .controlSize(.small)
                .tint(Theme.accent)
            Text(String(format: format, value.wrappedValue))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.text)
                .frame(width: 50, alignment: .trailing)
        }
    }

    // MARK: Spectrum

    private var spectrumCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("VISUALIZER")
            SiriWaveView(spectrum: engine.spectrum)
                .frame(height: 190)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .cardStyle()
        .frame(maxWidth: .infinity)
    }

    // MARK: App routing

    private var routingCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                sectionTitle("APP ROUTING")
                Spacer()
                Text("Send any app to its own output — it leaves the main EQ stream automatically")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.faint)
            }

            HStack(spacing: 12) {
                Picker("", selection: $routeSourceID) {
                    Text("Choose sound source…").tag("")
                    ForEach(engine.audioSources) { source in
                        Text(source.isPlaying ? "● \(source.name)" : source.name)
                            .tag(source.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)

                Image(systemName: "arrow.right")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.faint)

                Picker("", selection: $routeOutputID) {
                    Text("Choose output…").tag(AudioDeviceID(0))
                    ForEach(engine.outputDevices) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)

                Button {
                    engine.addRoute(sourceID: routeSourceID, outputID: routeOutputID)
                } label: {
                    Label("Add route", systemImage: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .disabled(routeSourceID.isEmpty || routeOutputID == 0)
            }

            if engine.routes.isEmpty {
                Text("Play audio in an app, pick the source marked ●, choose where it should go, then Add route.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.faint)
            } else {
                VStack(spacing: 8) {
                    ForEach(engine.routes) { route in
                        RouteRow(route: route,
                                 onRetry: { engine.retryRoute(route) },
                                 onRemove: { engine.removeRoute(route) })
                    }
                }
            }
        }
        .cardStyle()
    }

    private var quipFooter: some View {
        Text(quip)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(Theme.faint)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.top, 6)
            .padding(.bottom, 18)
            .id(quip)
            .transition(.opacity)
            .onReceive(quipTimer) { _ in
                withAnimation(.easeInOut(duration: 0.8)) {
                    quip = AEQQuips.random(excluding: quip)
                }
            }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .tracking(1.1)
            .foregroundStyle(Theme.muted)
    }
}

// MARK: - EQ Graph (curve + draggable dots, matching the design)

struct EQGraphView: View {
    @Binding var bands: [EQBand]
    private let maxDB: Float = 12

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                dbScale
                GeometryReader { geo in
                    ZStack {
                        gridAndCurve(size: geo.size)
                        dragZones(size: geo.size)
                    }
                }
                dbScale
            }
            frequencyLabels
        }
    }

    private var dbScale: some View {
        VStack {
            Text("+12"); Spacer()
            Text("+6"); Spacer()
            Text("0"); Spacer()
            Text("-6"); Spacer()
            Text("-12")
        }
        .font(.system(size: 10))
        .foregroundStyle(Theme.faint)
        .frame(width: 26)
    }

    private var frequencyLabels: some View {
        HStack(spacing: 0) {
            ForEach(Array(stride(from: 0, to: bands.count, by: 2)), id: \.self) { i in
                Text(bands[i].label)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.faint)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 30)
    }

    private func gridAndCurve(size: CGSize) -> some View {
        Canvas { context, canvasSize in
            let count = bands.count
            let step = canvasSize.width / CGFloat(count)

            for i in 0..<count {
                let x = step * (CGFloat(i) + 0.5)
                var line = Path()
                line.move(to: CGPoint(x: x, y: 0))
                line.addLine(to: CGPoint(x: x, y: canvasSize.height))
                context.stroke(line, with: .color(.white.opacity(0.05)), lineWidth: 1)
            }
            for row in 0...4 {
                let y = canvasSize.height * CGFloat(row) / 4
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y))
                line.addLine(to: CGPoint(x: canvasSize.width, y: y))
                context.stroke(line, with: .color(.white.opacity(row == 2 ? 0.12 : 0.05)),
                               lineWidth: 1)
            }

            let points: [CGPoint] = (0..<count).map { i in
                let x = step * (CGFloat(i) + 0.5)
                let ratio = CGFloat((bands[i].gain + maxDB) / (2 * maxDB))
                let y = canvasSize.height * (1 - min(max(ratio, 0), 1))
                return CGPoint(x: x, y: y)
            }

            var fill = Path()
            fill.move(to: CGPoint(x: points[0].x, y: canvasSize.height))
            for p in points { fill.addLine(to: p) }
            fill.addLine(to: CGPoint(x: points[points.count - 1].x, y: canvasSize.height))
            fill.closeSubpath()
            context.fill(fill, with: .color(Theme.accent.opacity(0.08)))

            var curve = Path()
            curve.move(to: points[0])
            for p in points.dropFirst() { curve.addLine(to: p) }
            context.stroke(curve, with: .color(Theme.accent), lineWidth: 2)

            for p in points {
                let dot = CGRect(x: p.x - 5.5, y: p.y - 5.5, width: 11, height: 11)
                context.fill(Path(ellipseIn: dot), with: .color(.white))
                context.stroke(Path(ellipseIn: dot.insetBy(dx: -1.5, dy: -1.5)),
                               with: .color(Theme.accent), lineWidth: 3)
            }
        }
    }

    private func dragZones(size: CGSize) -> some View {
        HStack(spacing: 0) {
            ForEach(bands.indices, id: \.self) { index in
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { drag in
                                let ratio = 1 - min(max(drag.location.y / size.height, 0), 1)
                                let gain = Float(ratio) * (2 * maxDB) - maxDB
                                bands[index].gain = min(max(gain, -maxDB), maxDB)
                            }
                    )
                    .onTapGesture(count: 2) {
                        bands[index].gain = 0
                    }
            }
        }
    }
}

// MARK: - Humor Strip

enum AEQQuips {
    static let all: [String] = [
        "Mixing engineers don't sleep. They just fade out.",
        "My EQ settings are flat. Unlike my life.",
        "Baila so good even the limiter started dancing \u{1F1F1}\u{1F1F0}",
        "Bass so deep it filed for residency below 40 Hz.",
        "I told a joke about a sine wave. It didn't get a good frequency response.",
        "Turning it up to 11 since the knob only went to 10.",
        "Audiophiles don't die. They just lose their high end.",
        "This app EQs everything. Except your Monday meetings.",
        "Warning: prolonged exposure to Baila may cause involuntary dancing.",
        "Compression: making loud things quiet and quiet things suspicious.",
        "The S in 'audiophile' stands for savings.",
        "Sub-bass: feelings you can't hear but your neighbors can.",
        "My two moods: Flat and +12 dB everywhere.",
        "A limiter walks into a bar. Just one. Never more.",
        "Treble seekers welcome. Bass dwellers tolerated. Mid lovers... interesting.",
        "Papare band at 90 dB > any notification sound \u{1F1F1}\u{1F1F0}",
        "Hot take: silence is just audio with commitment issues.",
        "EQ tip: when in doubt, blame the room.",
        "This visualizer is doing more cardio than all of us.",
        "Real-time FFT: because your music deserves math.",
        "Loudness war veteran. Lost some dynamic range out there.",
        "Don't trust an EQ preset named 'Perfect'. Nothing is.",
        "20 Hz to 20 kHz: the only range I exercise in.",
        "Somewhere, a kottu chef is keeping better rhythm than this beat \u{1F1F1}\u{1F1F0}",
        "Mids scooped. Confidence boosted."
    ]

    static func random(excluding current: String = "") -> String {
        var pick = all.randomElement() ?? ""
        while pick == current && all.count > 1 {
            pick = all.randomElement() ?? ""
        }
        return pick
    }
}

// MARK: - Siri-Inspired Visualizer
// Three flowing waves: bass drives the slow purple-pink wave,
// mids the blue wave, treble the fast teal shimmer.

struct SiriWaveView: View {
    var spectrum: [Float]

    private func bandAverage(_ range: Range<Int>) -> CGFloat {
        guard spectrum.count >= range.upperBound else { return 0 }
        let slice = spectrum[range]
        return CGFloat(slice.reduce(0, +)) / CGFloat(slice.count)
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let bass = bandAverage(0..<16)
                let mid = bandAverage(16..<40)
                let treble = bandAverage(40..<64)

                let waves: [(level: CGFloat, cycles: Double, speed: Double,
                             colors: [Color], lineWidth: CGFloat)] = [
                    (bass, 1.4, 1.0,
                     [Color(red: 0.62, green: 0.32, blue: 1.0),
                      Color(red: 0.96, green: 0.32, blue: 0.72)], 3.0),
                    (mid, 2.3, -1.5,
                     [Color(red: 0.30, green: 0.58, blue: 1.0),
                      Color(red: 0.55, green: 0.40, blue: 0.98)], 2.4),
                    (treble, 3.4, 2.1,
                     [Color(red: 0.28, green: 0.88, blue: 0.86),
                      Color(red: 0.38, green: 0.52, blue: 1.0)], 1.8)
                ]

                for (index, wave) in waves.enumerated() {
                    // Idle breathing keeps it alive even in silence
                    let breathe = 0.10 + 0.04 * CGFloat(sin(t * 0.9 + Double(index) * 2.1))
                    // Saturate at the card edge — loud peaks flatten against the
                    // border instead of escaping it
                    let raw = (breathe + wave.level * 1.15) * size.height * 0.42
                    let amplitude = min(raw, size.height * 0.46)

                    let gradient = Gradient(colors: wave.colors)
                    let shading = GraphicsContext.Shading.linearGradient(
                        gradient,
                        startPoint: .zero,
                        endPoint: CGPoint(x: size.width, y: 0)
                    )

                    for mirror in [CGFloat(1), CGFloat(-0.65)] {
                        var path = Path()
                        let steps = 96
                        for s in 0...steps {
                            let progress = Double(s) / Double(steps)
                            let x = size.width * CGFloat(progress)
                            let envelope = pow(sin(.pi * progress), 1.7)
                            let phase = t * wave.speed * 2 + Double(index) * 1.9
                            let angle = progress * 2 * .pi * wave.cycles + phase
                            let y = size.height / 2
                                + CGFloat(sin(angle)) * amplitude
                                * CGFloat(envelope) * mirror
                            if s == 0 {
                                path.move(to: CGPoint(x: x, y: y))
                            } else {
                                path.addLine(to: CGPoint(x: x, y: y))
                            }
                        }

                        var layer = context
                        if mirror < 0 { layer.opacity = 0.4 }

                        var glow = layer
                        glow.addFilter(.blur(radius: 7))
                        glow.stroke(path, with: shading, lineWidth: wave.lineWidth + 4)

                        layer.stroke(path, with: shading, lineWidth: wave.lineWidth)
                    }
                }
            }
        }
    }
}

// MARK: - Route Row

struct RouteRow: View {
    @ObservedObject var route: AppRoute
    var onRetry: () -> Void
    var onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(route.isActive ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            Text(route.appName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.text)
            Image(systemName: "arrow.right")
                .font(.system(size: 10))
                .foregroundStyle(Theme.faint)
            Text(route.outputDeviceName)
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
            Spacer()
            Text(route.statusText)
                .font(.system(size: 11))
                .foregroundStyle(Theme.faint)
                .lineLimit(1)
            if !route.isActive {
                Button("Retry", action: onRetry)
                    .font(.system(size: 12))
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
            }
            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border, lineWidth: 1))
    }
}

// MARK: - Card Style

extension View {
    func cardStyle() -> some View {
        self
            .padding(18)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Theme.border, lineWidth: 1)
            )
    }
}
