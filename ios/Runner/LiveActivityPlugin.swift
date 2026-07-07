import ActivityKit
import Flutter
import Foundation
import UIKit

// Registered in AppDelegate.didInitializeImplicitFlutterEngine
// ActivityContent API (content:staleDate:) requires iOS 16.2+
class LiveActivityPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {

    // MARK: - State

    @available(iOS 16.2, *)
    private var currentActivity: Activity<OrderTrackingAttributes>? {
        get { _currentActivity as? Activity<OrderTrackingAttributes> }
        set { _currentActivity = newValue }
    }
    private var _currentActivity: Any?
    private var tokenEventSink: FlutterEventSink?
    private var tokenTask: Task<Void, Never>?

    // MARK: - FlutterPlugin registration

    static func register(with registrar: FlutterPluginRegistrar) {
        let methodChannel = FlutterMethodChannel(
            name: "com.barbecuez.app/live_activity",
            binaryMessenger: registrar.messenger()
        )
        let eventChannel = FlutterEventChannel(
            name: "com.barbecuez.app/live_activity_token",
            binaryMessenger: registrar.messenger()
        )
        let instance = LiveActivityPlugin()
        registrar.addMethodCallDelegate(instance, channel: methodChannel)
        eventChannel.setStreamHandler(instance)
    }

    // MARK: - FlutterPlugin method dispatch

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard #available(iOS 16.2, *) else {
            result(FlutterError(
                code: "UNSUPPORTED",
                message: "Live Activities require iOS 16.2+",
                details: nil
            ))
            return
        }
        switch call.method {
        case "start":        startActivity(call: call, result: result)
        case "update":       updateActivity(call: call, result: result)
        case "end":          endActivity(call: call, result: result)
        case "getPushToken": getPushToken(result: result)
        default:             result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - FlutterStreamHandler (push token event channel)

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        tokenEventSink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        tokenEventSink = nil
        return nil
    }

    // MARK: - start

    @available(iOS 16.2, *)
    private func startActivity(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let orderNumber = args["orderNumber"] as? String,
              let orderType   = args["orderType"]   as? String,
              let totalAmount = args["totalAmount"] as? String,
              let status      = args["status"]      as? String,
              let statusLabel = args["statusLabel"] as? String,
              let etaMinutes  = args["etaMinutes"]  as? Int else {
            result(FlutterError(code: "INVALID_ARGS", message: "Missing required fields", details: nil))
            return
        }
        let progress    = (args["progress"]    as? Double) ?? 0.1
        let driverName  = args["driverName"]  as? String
        let driverPhone = args["driverPhone"] as? String

        let attributes = OrderTrackingAttributes(
            orderNumber: orderNumber,
            orderType: orderType,
            totalAmount: totalAmount
        )
        let initialState = OrderTrackingAttributes.ContentState(
            status: status,
            statusLabel: statusLabel,
            etaMinutes: etaMinutes,
            progress: progress,
            driverName: driverName,
            driverPhone: driverPhone
        )

        do {
            let activity = try Activity<OrderTrackingAttributes>.request(
                attributes: attributes,
                content: ActivityContent(
                    state: initialState,
                    staleDate: Date().addingTimeInterval(3600)
                ),
                pushType: .token
            )
            currentActivity = activity

            // Forward push token updates to Dart via EventChannel
            tokenTask?.cancel()
            tokenTask = Task {
                for await tokenData in activity.pushTokenUpdates {
                    let token = tokenData.map { String(format: "%02x", $0) }.joined()
                    await MainActor.run {
                        self.tokenEventSink?(["token": token, "activityId": activity.id])
                    }
                }
            }

            result(["activityId": activity.id])
        } catch {
            result(FlutterError(code: "START_FAILED", message: error.localizedDescription, details: nil))
        }
    }

    // MARK: - update

    @available(iOS 16.2, *)
    private func updateActivity(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let activity = currentActivity else {
            result(FlutterError(code: "NO_ACTIVITY", message: "No active Live Activity", details: nil))
            return
        }
        guard let args = call.arguments as? [String: Any],
              let status      = args["status"]      as? String,
              let statusLabel = args["statusLabel"] as? String,
              let etaMinutes  = args["etaMinutes"]  as? Int else {
            result(FlutterError(code: "INVALID_ARGS", message: "Missing required fields", details: nil))
            return
        }
        let progress    = (args["progress"]    as? Double) ?? 0.5
        let driverName  = args["driverName"]  as? String
        let driverPhone = args["driverPhone"] as? String

        let newState = OrderTrackingAttributes.ContentState(
            status: status,
            statusLabel: statusLabel,
            etaMinutes: etaMinutes,
            progress: progress,
            driverName: driverName,
            driverPhone: driverPhone
        )
        Task {
            await activity.update(
                ActivityContent(state: newState, staleDate: Date().addingTimeInterval(1800))
            )
            await MainActor.run { result(nil) }
        }
    }

    // MARK: - end

    @available(iOS 16.2, *)
    private func endActivity(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let activity = currentActivity else {
            result(nil)
            return
        }
        let args       = call.arguments as? [String: Any]
        let statusLabel = (args?["statusLabel"] as? String) ?? "Order completed"

        let finalState = OrderTrackingAttributes.ContentState(
            status: "delivered",
            statusLabel: statusLabel,
            etaMinutes: 0,
            progress: 1.0
        )
        Task {
            await activity.end(
                ActivityContent(state: finalState, staleDate: nil),
                dismissalPolicy: .after(.now + 60)
            )
            self.currentActivity = nil
            self.tokenTask?.cancel()
            await MainActor.run { result(nil) }
        }
    }

    // MARK: - getPushToken

    @available(iOS 16.2, *)
    private func getPushToken(result: @escaping FlutterResult) {
        guard let activity = currentActivity else {
            result(FlutterError(code: "NO_ACTIVITY", message: "No active Live Activity", details: nil))
            return
        }
        guard let tokenData = activity.pushToken else {
            result(FlutterError(code: "TOKEN_NOT_READY", message: "Push token not yet available", details: nil))
            return
        }
        let token = tokenData.map { String(format: "%02x", $0) }.joined()
        result(["token": token])
    }
}
