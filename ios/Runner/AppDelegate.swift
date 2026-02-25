import UIKit
import Flutter
import AVFoundation

// MARK: - Local LLM Stream Handler
final class LocalLlmStreamHandler: NSObject, FlutterStreamHandler {
  private var eventSink: FlutterEventSink?
  private var cancelled: Bool = false

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    cancelled = false
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    cancelled = true
    eventSink = nil
    return nil
  }

  func send(_ event: Any) {
    if cancelled { return }
    if let sink = eventSink {
      sink(event)
    }
  }

  func sendChunk(_ chunk: String) {
    if chunk == "<eop>" {
      sendDone()
    } else {
      send(["type": "chunk", "data": chunk])
    }
  }

  func sendDone() {
    send(["type": "done"])
  }

  func sendError(_ error: String) {
    send(["type": "error", "data": error])
  }

  func cancel() {
    cancelled = true
  }
}

final class LocalTtsStreamHandler: NSObject, FlutterStreamHandler, AVSpeechSynthesizerDelegate {
  private var eventSink: FlutterEventSink?
  private var cancelled: Bool = false
  private let synthesizer: AVSpeechSynthesizer = AVSpeechSynthesizer()
  private var fallbackSession: Int = 0
  private var fallbackToken: String = ""
  private var utteranceTokens: [ObjectIdentifier: (Int, String)] = [:]
  private var activeUtteranceKey: ObjectIdentifier?
  private var pollTimer: Timer?
  private var activeStartSent: Bool = false

  override init() {
    super.init()
    synthesizer.delegate = self
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    cancelled = false
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    cancelled = true
    eventSink = nil
    return nil
  }

  private func send(_ event: Any) {
    if cancelled { return }
    guard let sink = eventSink else { return }
    if Thread.isMainThread {
      sink(event)
    } else {
      DispatchQueue.main.async {
        sink(event)
      }
    }
  }

  func speak(text: String, rate: Double, session: Int, lang: String?, token: String?) {
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
    let utterance = AVSpeechUtterance(string: text)
    let tk = token ?? ""
    fallbackSession = session
    fallbackToken = tk
    let key = ObjectIdentifier(utterance)
    utteranceTokens[key] = (session, tk)
    activeUtteranceKey = key
    activeStartSent = false
    pollTimer?.invalidate()
    pollTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [weak self] t in
      guard let self = self else { return }
      if self.cancelled { t.invalidate(); return }
      guard let activeKey = self.activeUtteranceKey else { t.invalidate(); return }
      if self.synthesizer.isSpeaking {
        if !self.activeStartSent {
          self.activeStartSent = true
          let payload = self.utteranceTokens[activeKey]
          let session = payload?.0 ?? self.fallbackSession
          let token = payload?.1 ?? self.fallbackToken
          self.send(["type": "start", "session": session, "token": token])
        }
        return
      }
      if !self.activeStartSent { return }
      let payload = self.utteranceTokens.removeValue(forKey: activeKey)
      if payload == nil { return }
      let session = payload?.0 ?? self.fallbackSession
      let token = payload?.1 ?? self.fallbackToken
      self.send(["type": "done", "session": session, "token": token])
      self.activeUtteranceKey = nil
      self.activeStartSent = false
      t.invalidate()
    }
    if let lang = lang {
      utterance.voice = AVSpeechSynthesisVoice(language: lang)
    }
    let base = AVSpeechUtteranceDefaultSpeechRate
    let scaled = Float(base) * Float(rate)
    utterance.rate = min(max(scaled, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
    synthesizer.speak(utterance)
  }

  func stop() {
    utteranceTokens.removeAll()
    activeUtteranceKey = nil
    activeStartSent = false
    pollTimer?.invalidate()
    pollTimer = nil
    synthesizer.stopSpeaking(at: .immediate)
  }

  func isSpeaking() -> Bool {
    return synthesizer.isSpeaking
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
    let key = ObjectIdentifier(utterance)
    activeUtteranceKey = key
    if activeStartSent { return }
    activeStartSent = true
    let payload = utteranceTokens[key]
    let session = payload?.0 ?? fallbackSession
    let token = payload?.1 ?? fallbackToken
    send(["type": "start", "session": session, "token": token])
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    let key = ObjectIdentifier(utterance)
    let payload = utteranceTokens.removeValue(forKey: key)
    if payload == nil { return }
    let session = payload?.0 ?? fallbackSession
    let token = payload?.1 ?? fallbackToken
    send(["type": "done", "session": session, "token": token])
    if activeUtteranceKey == key {
      activeUtteranceKey = nil
      activeStartSent = false
      pollTimer?.invalidate()
      pollTimer = nil
    }
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    let key = ObjectIdentifier(utterance)
    let payload = utteranceTokens.removeValue(forKey: key)
    if payload == nil { return }
    let session = payload?.0 ?? fallbackSession
    let token = payload?.1 ?? fallbackToken
    send(["type": "done", "session": session, "token": token])
    if activeUtteranceKey == key {
      activeUtteranceKey = nil
      activeStartSent = false
      pollTimer?.invalidate()
      pollTimer = nil
    }
  }
}

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var mnnLlmBridge: MnnLlmBridge?
  
  /// 按需创建 MnnLlmBridge（延迟实例化，避免启动时占用内存）
  private func ensureMnnBridge() -> MnnLlmBridge {
    if let bridge = mnnLlmBridge {
      return bridge
    }
    let bridge = MnnLlmBridge()
    mnnLlmBridge = bridge
    return bridge
  }
  
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    
    // 安全地获取 FlutterViewController
    guard let controller = self.flutterController else {
      print("Warning: Could not get FlutterViewController")
      return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }
    
    setupMethodChannels(controller: controller)
    
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
  
  private var flutterController: FlutterViewController? {
    // 尝试多种方式获取 FlutterViewController
    if let controller = window?.rootViewController as? FlutterViewController {
      return controller
    }
    // iOS 13+ 场景委托模式
    if #available(iOS 13.0, *) {
      for scene in UIApplication.shared.connectedScenes {
        if let windowScene = scene as? UIWindowScene,
           let controller = windowScene.windows.first?.rootViewController as? FlutterViewController {
          return controller
        }
      }
    }
    return nil
  }
  
  private func setupMethodChannels(controller: FlutterViewController) {
    // MARK: - MNN LLM 功能（MnnLlmBridge 延迟创建，首次 initialize 时才实例化）
    let localLlmStreamHandler = LocalLlmStreamHandler()
    let localLlmEventChannel = FlutterEventChannel(name: "airread/local_llm_stream", binaryMessenger: controller.binaryMessenger)
    localLlmEventChannel.setStreamHandler(localLlmStreamHandler)

    let localLlmChannel = FlutterMethodChannel(name: "airread/local_llm", binaryMessenger: controller.binaryMessenger)
    localLlmChannel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }

      switch call.method {
      case "isAvailable":
        let available = MnnLlmBridge.isAvailable()
        result(available)

      case "initialize":
        guard let args = call.arguments as? [String: Any],
              let modelPath = args["modelPath"] as? String else {
          result(FlutterError(code: "INVALID_ARGS", message: "Missing modelPath", details: nil))
          return
        }

        // 延迟创建 MnnLlmBridge（首次 initialize 时才分配内存）
        let bridge = self.ensureMnnBridge()
        bridge.initialize(modelPath, completion: { success in
            if success {
                result(true)
            } else {
                result(FlutterError(code: "INIT_FAILED", message: "Failed to initialize model", details: nil))
            }
        })

      case "chatOnce":
        guard let args = call.arguments as? [String: Any],
              let userText = args["userText"] as? String else {
          result(FlutterError(code: "INVALID_ARGS", message: "Missing userText", details: nil))
          return
        }

        DispatchQueue.global(qos: .userInitiated).async {
          let response = self.mnnLlmBridge?.chatOnce(
            userText
          )
          
          DispatchQueue.main.async {
            if let response = response {
              result(response)
            } else {
              result(FlutterError(code: "GENERATION_FAILED", message: "Generation failed", details: nil))
            }
          }
        }

      case "chatStream":
        guard let args = call.arguments as? [String: Any],
              let userText = args["userText"] as? String else {
          result(FlutterError(code: "INVALID_ARGS", message: "Missing userText", details: nil))
          return
        }


        // 开始流式生成
        self.mnnLlmBridge?.chatStream(
          userText,
          onChunk: { chunk in
            localLlmStreamHandler.sendChunk(chunk)
          },
          onDone: { error in
            if let error = error {
              localLlmStreamHandler.sendError(error.localizedDescription)
            } else {
              localLlmStreamHandler.sendDone()
            }
          }
        )

        result(nil)

      case "cancelChatStream":
        self.mnnLlmBridge?.cancelCurrentStream()
        localLlmStreamHandler.cancel()
        result(nil)

      case "dispose":
        NSLog("[MnnLlmBridge] dispose requested")
        self.mnnLlmBridge?.dispose()
        result(nil)

      case "dumpConfig":
        let config = self.mnnLlmBridge?.dumpConfig()
        result(config)

      case "logcat":
        // 仅用于 Android，iOS 直接返回成功
        result(nil)

      default:
        result(FlutterMethodNotImplemented)
      }
    }

    // TTS 功能
    let ttsStreamHandler = LocalTtsStreamHandler()
    let ttsEventChannel = FlutterEventChannel(name: "airread/local_tts_events", binaryMessenger: controller.binaryMessenger)
    ttsEventChannel.setStreamHandler(ttsStreamHandler)
    let ttsChannel = FlutterMethodChannel(name: "airread/local_tts", binaryMessenger: controller.binaryMessenger)
    ttsChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "speak":
        let args = call.arguments as? [String: Any]
        let text = args?["text"] as? String ?? ""
        let rate = (args?["rate"] as? NSNumber)?.doubleValue ?? 1.0
        let session = (args?["session"] as? NSNumber)?.intValue ?? 0
        let lang = args?["lang"] as? String
        let token = args?["token"] as? String
        ttsStreamHandler.speak(text: text, rate: rate, session: session, lang: lang, token: token)
        result(nil)
      case "stop":
        ttsStreamHandler.stop()
        result(nil)
      case "isSpeaking":
        result(ttsStreamHandler.isSpeaking())
      case "isAvailable":
        result(true)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
