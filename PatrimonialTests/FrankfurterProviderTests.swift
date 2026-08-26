import Foundation
import Testing
@testable import Patrimonial

struct FrankfurterProviderTests {

    // MARK: - Response decoding

    @Test func decodesValidResponse() throws {
        let json = """
        {"amount":1.0,"base":"USD","date":"2026-03-20","rates":{"EUR":0.9234}}
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(FrankfurterResponse.self, from: json)
        #expect(response.base == "USD")
        #expect(response.date == "2026-03-20")
        #expect(response.rates["EUR"] == 0.9234)
    }

    @Test func decodesMultipleCurrencies() throws {
        let json = """
        {"amount":1.0,"base":"USD","date":"2026-03-20","rates":{"EUR":0.9234,"GBP":0.7891}}
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(FrankfurterResponse.self, from: json)
        #expect(response.rates.count == 2)
        #expect(response.rates["GBP"] == 0.7891)
    }

    @Test func decodesEmptyRates() throws {
        let json = """
        {"amount":1.0,"base":"USD","date":"2026-03-20","rates":{}}
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(FrankfurterResponse.self, from: json)
        #expect(response.rates.isEmpty)
    }

    // MARK: - Weekend adjustment

    @Test func saturdayAdjustsToFriday() {
        let cal = Calendar(identifier: .gregorian)
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 3
        comps.day = 21  // Saturday
        comps.timeZone = TimeZone(identifier: "UTC")
        let saturday = cal.date(from: comps)!

        let adjusted = FrankfurterProvider.adjustToBusinessDay(saturday)
        let day = cal.component(.weekday, from: adjusted)
        #expect(day == 6) // Friday
        #expect(cal.component(.day, from: adjusted) == 20)
    }

    @Test func sundayAdjustsToFriday() {
        let cal = Calendar(identifier: .gregorian)
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 3
        comps.day = 22  // Sunday
        comps.timeZone = TimeZone(identifier: "UTC")
        let sunday = cal.date(from: comps)!

        let adjusted = FrankfurterProvider.adjustToBusinessDay(sunday)
        let day = cal.component(.weekday, from: adjusted)
        #expect(day == 6) // Friday
        #expect(cal.component(.day, from: adjusted) == 20)
    }

    @Test func weekdayIsUnchanged() {
        let cal = Calendar(identifier: .gregorian)
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 3
        comps.day = 18  // Wednesday
        comps.timeZone = TimeZone(identifier: "UTC")
        let wednesday = cal.date(from: comps)!

        let adjusted = FrankfurterProvider.adjustToBusinessDay(wednesday)
        let adjustedDay = cal.component(.day, from: adjusted)
        #expect(adjustedDay == 18)
    }

    // MARK: - Date formatting

    @Test func formatDateProducesISO() {
        let cal = Calendar(identifier: .gregorian)
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 3
        comps.day = 20
        comps.timeZone = TimeZone(identifier: "UTC")
        let date = cal.date(from: comps)!

        let str = FrankfurterProvider.formatDate(date)
        #expect(str == "2026-03-20")
    }

    // MARK: - FXError descriptions

    @Test func fxErrorDescriptions() {
        let e1 = FXError.invalidRequest
        #expect(e1.localizedDescription.contains("inválido"))

        let e2 = FXError.networkError
        #expect(e2.localizedDescription.contains("rede"))

        let e3 = FXError.currencyNotFound("XYZ")
        #expect(e3.localizedDescription.contains("XYZ"))
    }
}
