import ActivityKit
import Foundation

public struct OrderTrackingAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var status: String       // pending | preparing | ready | out_for_delivery | delivered
        public var statusLabel: String
        public var etaMinutes: Int
        public var progress: Double     // 0.0 – 1.0
        public var driverName: String?
        public var driverPhone: String?

        public init(
            status: String,
            statusLabel: String,
            etaMinutes: Int,
            progress: Double,
            driverName: String? = nil,
            driverPhone: String? = nil
        ) {
            self.status = status
            self.statusLabel = statusLabel
            self.etaMinutes = etaMinutes
            self.progress = progress
            self.driverName = driverName
            self.driverPhone = driverPhone
        }
    }

    public var orderNumber: String
    public var orderType: String    // delivery | takeaway
    public var totalAmount: String

    public init(orderNumber: String, orderType: String, totalAmount: String) {
        self.orderNumber = orderNumber
        self.orderType = orderType
        self.totalAmount = totalAmount
    }
}
