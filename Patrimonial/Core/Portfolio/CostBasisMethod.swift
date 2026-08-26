import Foundation

enum CostBasisMethod: String, Codable, CaseIterable, Sendable {
    case average
    case fifo
}

struct CostBasisMethodNotImplemented: Error, LocalizedError {
    let method: CostBasisMethod
    var errorDescription: String? { "Método de custo \(method.rawValue) não implementado" }
}
