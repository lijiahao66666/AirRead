import UIKit
import Flutter

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
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
