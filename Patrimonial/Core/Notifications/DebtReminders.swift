import UserNotifications
import SwiftData

enum DebtReminders {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in }
    }

    @MainActor
    static func scheduleAll(in context: ModelContext) {
        guard let debts = try? context.fetch(FetchDescriptor<Debt>()) else { return }

        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: debts.map { "debt-due-\($0.id)" })

        for debt in debts where !debt.isSettled {
            guard let due = debt.dueDate else { continue }

            let daysUntilDue = Calendar.current.dateComponents([.day], from: Date(), to: due).day ?? 0
            guard daysUntilDue >= 0 else { continue }

            if daysUntilDue <= 3 {
                scheduleNotification(
                    id: "debt-due-\(debt.id)",
                    title: "Dívida a vencer",
                    body: dueSoonBody(debt: debt, daysUntilDue: daysUntilDue),
                    date: daysUntilDue == 0 ? Date().addingTimeInterval(60) : due.addingTimeInterval(-86400),
                    center: center
                )
            } else if daysUntilDue <= 7 {
                scheduleNotification(
                    id: "debt-due-\(debt.id)",
                    title: "Dívida próxima do prazo",
                    body: "\(debt.counterparty): \(DebtAmount.editable(debt.outstanding)) € vencem em \(daysUntilDue) dias.",
                    date: due.addingTimeInterval(-3 * 86400),
                    center: center
                )
            }
        }
    }

    private static func dueSoonBody(debt: Debt, daysUntilDue: Int) -> String {
        let amount = DebtAmount.editable(debt.outstanding)
        if daysUntilDue == 0 {
            return "\(debt.counterparty): \(amount) € vence hoje."
        }
        return "\(debt.counterparty): \(amount) € vence amanhã."
    }

    private static func scheduleNotification(id: String, title: String, body: String, date: Date, center: UNUserNotificationCenter) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)

        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }
}
