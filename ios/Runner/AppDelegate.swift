import UIKit
import Flutter
import AVFoundation

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
    if let sink = eventSink {
      sink(event)
    }
  }

  func speak(text: String, rate: Double, session: Int, lang: String?) {
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
    currentSession = session
    if synthesizer.isSpeaking {
      synthesizer.stopSpeaking(at: .immediate)
    }
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

@UIApplicationMain
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let controller = window?.rootViewController as? FlutterViewController {
      let streamHandler = LocalLlmStreamHandler()
      let eventChannel = FlutterEventChannel(name: "airread/local_llm_stream", binaryMessenger: controller.binaryMessenger)
      eventChannel.setStreamHandler(streamHandler)
      let channel = FlutterMethodChannel(name: "airread/local_llm", binaryMessenger: controller.binaryMessenger)
      channel.setMethodCallHandler { call, result in
        switch call.method {
        case "isAvailable":
          result(MnnLlmBridge.isAvailable())
        case "init":
          let args = call.arguments as? [String: Any]
          let modelPath = args?["modelPath"] as? String ?? ""
          DispatchQueue.global(qos: .userInitiated).async {
            var err: NSError?
            MnnLlmBridge.initialize(withModelPath: modelPath, error: &err)
            DispatchQueue.main.async {
              if let err = err {
                result(FlutterError(code: "NATIVE_ERR", message: "Native init failed", details: err.localizedDescription))
              } else {
                result(nil)
              }
            }
          }
        case "chatOnce":
          let args = call.arguments as? [String: Any]
          let modelPath = args?["modelPath"] as? String ?? ""
          let userText = args?["userText"] as? String ?? ""
          let maxNewTokens = (args?["maxNewTokens"] as? NSNumber)?.intValue ?? 1024
          let maxInputTokens = (args?["maxInputTokens"] as? NSNumber)?.intValue ?? 0
          let temperature = (args?["temperature"] as? NSNumber)?.doubleValue ?? -1.0
          let topP = (args?["top_p"] as? NSNumber)?.doubleValue ?? -1.0
          let topK = (args?["top_k"] as? NSNumber)?.intValue ?? -1
          let minP = (args?["min_p"] as? NSNumber)?.doubleValue ?? -1.0
          let presencePenalty = (args?["presence_penalty"] as? NSNumber)?.doubleValue ?? -1.0
          let repetitionPenalty = (args?["repetition_penalty"] as? NSNumber)?.doubleValue ?? -1.0
          let enableThinking = (args?["enable_thinking"] as? Bool).map { $0 ? 1 : 0 } ?? -1
          DispatchQueue.global(qos: .userInitiated).async {
            var initErr: NSError?
            MnnLlmBridge.initialize(withModelPath: modelPath, error: &initErr)
            if let initErr = initErr {
              DispatchQueue.main.async {
                result(FlutterError(code: "NATIVE_ERR", message: "Native init failed", details: initErr.localizedDescription))
              }
              return
            }
            var chatErr: NSError?
            let resp = MnnLlmBridge.chatOnce(
              userText,
              maxNewTokens: maxNewTokens,
              maxInputTokens: maxInputTokens,
              temperature: temperature,
              topP: topP,
              topK: topK,
              minP: minP,
              presencePenalty: presencePenalty,
              repetitionPenalty: repetitionPenalty,
              enableThinking: enableThinking,
              error: &chatErr
            )
            DispatchQueue.main.async {
              if let chatErr = chatErr {
                result(FlutterError(code: "NATIVE_ERR", message: "Native chat failed", details: chatErr.localizedDescription))
              } else {
                result(resp)
              }
            }
          }
        case "chatStream":
          let args = call.arguments as? [String: Any]
          let modelPath = args?["modelPath"] as? String ?? ""
          let userText = args?["userText"] as? String ?? ""
          let maxNewTokens = (args?["maxNewTokens"] as? NSNumber)?.intValue ?? 1024
          let maxInputTokens = (args?["maxInputTokens"] as? NSNumber)?.intValue ?? 0
          let temperature = (args?["temperature"] as? NSNumber)?.doubleValue ?? -1.0
          let topP = (args?["top_p"] as? NSNumber)?.doubleValue ?? -1.0
          let topK = (args?["top_k"] as? NSNumber)?.intValue ?? -1
          let minP = (args?["min_p"] as? NSNumber)?.doubleValue ?? -1.0
          let presencePenalty = (args?["presence_penalty"] as? NSNumber)?.doubleValue ?? -1.0
          let repetitionPenalty = (args?["repetition_penalty"] as? NSNumber)?.doubleValue ?? -1.0
          let enableThinking = (args?["enable_thinking"] as? Bool).map { $0 ? 1 : 0 } ?? -1
          DispatchQueue.global(qos: .userInitiated).async {
            var initErr: NSError?
            MnnLlmBridge.initialize(withModelPath: modelPath, error: &initErr)
            if let initErr = initErr {
              DispatchQueue.main.async {
                streamHandler.send(["type": "error", "message": initErr.localizedDescription])
                streamHandler.send(["type": "done"])
              }
              return
            }
            MnnLlmBridge.chatStream(
              userText,
              maxNewTokens: maxNewTokens,
              maxInputTokens: maxInputTokens,
              temperature: temperature,
              topP: topP,
              topK: topK,
              minP: minP,
              presencePenalty: presencePenalty,
              repetitionPenalty: repetitionPenalty,
              enableThinking: enableThinking,
              onChunk: { chunk in
              DispatchQueue.main.async {
                streamHandler.send(["type": "chunk", "data": chunk])
              }
            }, onDone: { err in
              DispatchQueue.main.async {
                if let err = err {
                  streamHandler.send(["type": "error", "message": err.localizedDescription])
                }
                streamHandler.send(["type": "done"])
              }
            })
          }
          result(nil)
        case "cancelChatStream":
          streamHandler.cancel()
          MnnLlmBridge.cancelCurrentStream()
          result(nil)
        case "dumpConfig":
          DispatchQueue.global(qos: .userInitiated).async {
            var err: NSError?
            let cfg = MnnLlmBridge.dumpConfig(withError: &err)
            DispatchQueue.main.async {
              if let err = err {
                result(FlutterError(code: "NATIVE_ERR", message: "Native dumpConfig failed", details: err.localizedDescription))
              } else {
                result(cfg)
              }
            }
          }
        default:
          result(FlutterMethodNotImplemented)
        }
      }

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
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
