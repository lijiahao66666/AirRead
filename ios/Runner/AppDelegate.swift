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
  private var currentSession: Int = 0

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

  func speak(text: String, rate: Double, session: Int, lang: String?) {
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
    if synthesizer.isSpeaking {
      synthesizer.stopSpeaking(at: .immediate)
    }
    currentSession = session
    let utterance = AVSpeechUtterance(string: text)
    if let lang = lang {
      utterance.voice = AVSpeechSynthesisVoice(language: lang)
    }
    let base = AVSpeechUtteranceDefaultSpeechRate
    let scaled = Float(base) * Float(rate)
    utterance.rate = min(max(scaled, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
    synthesizer.speak(utterance)
  }

  func stop() {
    synthesizer.stopSpeaking(at: .immediate)
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    send(["type": "done", "session": currentSession])
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    send(["type": "done", "session": currentSession])
  }
}

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var mnnLlmBridge: MnnLlmBridge?
  
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
    // MARK: - MNN LLM 功能
    mnnLlmBridge = MnnLlmBridge()
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

        // modelPath 已经是完整路径，直接使用
        // 使用异步初始化
        self.mnnLlmBridge?.initialize(modelPath, completion: { success in
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

        let maxNewTokens = (args["maxNewTokens"] as? NSNumber)?.intValue ?? 512
        let maxInputTokens = (args["maxInputTokens"] as? NSNumber)?.intValue ?? 2048
        let temperature = (args["temperature"] as? NSNumber)?.doubleValue ?? 0.7
        let topP = (args["topP"] as? NSNumber)?.doubleValue ?? 0.9
        let topK = (args["topK"] as? NSNumber)?.intValue ?? 40
        let minP = (args["minP"] as? NSNumber)?.doubleValue ?? 0.05
        let presencePenalty = (args["presencePenalty"] as? NSNumber)?.doubleValue ?? 0.0
        let repetitionPenalty = (args["repetitionPenalty"] as? NSNumber)?.doubleValue ?? 1.0
        let enableThinking = (args["enableThinking"] as? NSNumber)?.boolValue ?? false

        let response = self.mnnLlmBridge?.chatOnce(
          userText,
          maxNewTokens: Int(maxNewTokens),
          maxInputTokens: Int(maxInputTokens),
          temperature: temperature,
          topP: topP,
          topK: Int(topK),
          minP: minP,
          presencePenalty: presencePenalty,
          repetitionPenalty: repetitionPenalty,
          enableThinking: enableThinking
        )

        if let response = response {
          result(response)
        } else {
          result(FlutterError(code: "GENERATION_FAILED", message: "Generation failed", details: nil))
        }

      case "chatStream":
        guard let args = call.arguments as? [String: Any],
              let userText = args["userText"] as? String else {
          result(FlutterError(code: "INVALID_ARGS", message: "Missing userText", details: nil))
          return
        }

        let maxNewTokens = (args["maxNewTokens"] as? NSNumber)?.intValue ?? 512
        let maxInputTokens = (args["maxInputTokens"] as? NSNumber)?.intValue ?? 2048
        let temperature = (args["temperature"] as? NSNumber)?.doubleValue ?? 0.7
        let topP = (args["topP"] as? NSNumber)?.doubleValue ?? 0.9
        let topK = (args["topK"] as? NSNumber)?.intValue ?? 40
        let minP = (args["minP"] as? NSNumber)?.doubleValue ?? 0.05
        let presencePenalty = (args["presencePenalty"] as? NSNumber)?.doubleValue ?? 0.0
        let repetitionPenalty = (args["repetitionPenalty"] as? NSNumber)?.doubleValue ?? 1.0
        let enableThinking = (args["enableThinking"] as? NSNumber)?.boolValue ?? false

        // 开始流式生成
        self.mnnLlmBridge?.chatStream(
          userText,
          maxNewTokens: Int(maxNewTokens),
          maxInputTokens: Int(maxInputTokens),
          temperature: temperature,
          topP: topP,
          topK: Int(topK),
          minP: minP,
          presencePenalty: presencePenalty,
          repetitionPenalty: repetitionPenalty,
          enableThinking: enableThinking,
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
        ttsStreamHandler.speak(text: text, rate: rate, session: session, lang: lang)
        result(nil)
      case "stop":
        ttsStreamHandler.stop()
        result(nil)
      case "isAvailable":
        result(true)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
