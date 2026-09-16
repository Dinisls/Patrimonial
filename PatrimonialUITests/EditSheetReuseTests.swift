import XCTest

/// Exercises the Dashboard's edit-sheet flow that `.id(tx.txID)` on
/// `TransactionEditSheet` protects.
///
/// `TransactionEditSheet` seeds every editable `@State` in its `init(tx:)`.
/// With `.sheet(item:)` SwiftUI can reuse the sheet's view identity between
/// presentations and keep the first transaction's values — Guardar would then
/// write them onto the second, silently overwriting it. Keying the sheet on the
/// transaction's own UUID forces fresh state every time; the two sibling call
/// sites (PBMovimentos) carry the same `.id` for the same reason.
///
/// CAVEAT — this is a *behaviour* guard, not a proof that `.id` is load-bearing
/// here. On iOS 26.4 removing the `.id` leaves both tests green: the only
/// reachable Dashboard path is open A → dismiss → open B, and SwiftUI reseeds
/// the sheet's `@State` after the dismissal tears it down. The reuse corruption
/// needs the item to change A→B with no intervening dismissal, which this screen
/// does not expose. So these tests pin the reachable behaviour and would catch a
/// regression in the surrounding seed/save logic, but cannot turn red on `.id`
/// alone on this OS. Kept because the guard is cheap and OS behaviour has
/// historically differed across versions.
///
/// The two rows come from `PBDebug.seedEditSheetRows` (`PB_SEED_EDIT=1`),
/// future-dated so they sit at the top of "Transações recentes":
/// A = "UITEST-A Alfa" / 111, B = "UITEST-B Bravo" / 222.
final class EditSheetReuseTests: XCTestCase {

    private let rowA = "UITEST-A Alfa"
    private let rowB = "UITEST-B Bravo"

    override func setUp() {
        continueAfterFailure = false
    }

    private func launchOnDashboard() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["PB_SEED_EDIT"] = "1"
        app.launchEnvironment["PB_TAB"] = "0"
        app.launch()
        XCTAssertTrue(app.navigationBars["Resumo"].waitForExistence(timeout: 5),
                      "o Resumo não abriu")
        return app
    }

    private func row(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
    }

    private func openRow(_ title: String, in app: XCUIApplication) {
        let button = row(title, in: app)
        XCTAssertTrue(button.waitForExistence(timeout: 5), "a linha \(title) não apareceu")
        button.tap()
        XCTAssertTrue(app.navigationBars["Editar Transação"].waitForExistence(timeout: 5),
                      "o editor não abriu para \(title)")
    }

    private func closeEditor(_ app: XCUIApplication) {
        app.buttons["Cancelar"].tap()
        XCTAssertTrue(app.navigationBars["Editar Transação"].waitForNonExistence(timeout: 5),
                      "o editor não fechou")
    }

    /// The visual half: open A, close it, open B — the fields must show B, not A.
    /// Without `.id`, the "Descrição" field still reads A's title.
    func testOpeningASecondTransactionShowsItsOwnValues() {
        let app = launchOnDashboard()

        openRow(rowA, in: app)
        let field = app.textFields["Descrição"]
        XCTAssertEqual(field.value as? String, rowA, "o editor de A não semeou A")
        closeEditor(app)

        openRow(rowB, in: app)
        XCTAssertEqual(field.value as? String, rowB,
                       "o editor reutilizou os @State: abriu B mas mostra os dados de A")
        closeEditor(app)
    }

    /// The half that matters: after opening A then B, saving B unchanged must
    /// leave B with B's data. Without `.id`, Guardar writes A's stale @State onto
    /// B's txID — B is silently overwritten and its title disappears from the list.
    func testSavingSecondTransactionDoesNotOverwriteItWithTheFirst() {
        let app = launchOnDashboard()

        openRow(rowA, in: app)
        closeEditor(app)

        openRow(rowB, in: app)
        app.buttons["Guardar"].tap()
        XCTAssertTrue(app.navigationBars["Editar Transação"].waitForNonExistence(timeout: 5),
                      "o editor não fechou após Guardar")

        // B still carries its own title. With the bug it would now read
        // "UITEST-A Alfa" and rowB's text would be gone from the list entirely.
        XCTAssertTrue(app.staticTexts[rowB].waitForExistence(timeout: 5),
                      "guardar B sobrescreveu-a com os dados de A")
        // And A is untouched: exactly one A row, not two.
        XCTAssertTrue(app.staticTexts[rowA].exists, "a linha A desapareceu")
    }
}
