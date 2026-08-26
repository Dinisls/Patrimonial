import XCTest

/// The tabs actually render after the price store moved into the environment.
///
/// `PortfolioScreen` used to own its `PriceStore` as `@State`; it now reads it
/// with `@Environment(PriceStore.self)`, and a missing environment value is a
/// crash at render time, not a compile error. Nothing in the unit tests can see
/// that — they never build a view — so this walks the two screens the change
/// touched.
final class ResetAndPortfolioSmokeTests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    func testInvestmentsTabRenders() {
        let app = XCUIApplication()
        app.launch()

        app.buttons["Investimentos"].tap()
        XCTAssertTrue(
            app.navigationBars["Investimentos"].waitForExistence(timeout: 5),
            "o separador Investimentos não abriu"
        )
    }

    /// The reset lives at the bottom of Definições and must be a two-step
    /// confirmation. A single destructive tap would be a trap, so the test
    /// asserts the first alert appears and *stops* there — it never taps through
    /// to the second, which would wipe the simulator's data.
    func testResetIsATwoStepConfirmation() {
        let app = XCUIApplication()
        app.launch()

        app.buttons["gearshape"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Definições"].waitForExistence(timeout: 5))

        let reset = app.buttons["Apagar todos os dados"]
        XCTAssertTrue(reset.waitForExistence(timeout: 5))
        reset.tap()

        let firstAlert = app.alerts["Apagar todos os dados?"]
        XCTAssertTrue(firstAlert.waitForExistence(timeout: 5), "faltou o primeiro alerta")
        // The counts are the reason this alert exists.
        XCTAssertTrue(
            firstAlert.staticTexts.element(boundBy: 1).label.contains("transaç"),
            "o alerta não diz quantas transações vão desaparecer"
        )
        XCTAssertTrue(firstAlert.buttons["Continuar"].exists)

        firstAlert.buttons["Continuar"].tap()

        let secondAlert = app.alerts["De certeza?"]
        XCTAssertTrue(secondAlert.waitForExistence(timeout: 5), "faltou o segundo alerta")
        XCTAssertTrue(secondAlert.buttons["Apagar tudo"].exists)

        // Backing out leaves everything alone, which is the other half of the
        // contract.
        secondAlert.buttons["Cancelar"].tap()
        XCTAssertTrue(app.navigationBars["Definições"].waitForExistence(timeout: 5))
    }
}
