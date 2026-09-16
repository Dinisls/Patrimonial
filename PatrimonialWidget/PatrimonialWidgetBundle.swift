import WidgetKit
import SwiftUI

@main
struct PatrimonialWidgetBundle: WidgetBundle {
    var body: some Widget {
        PatrimonialWidget()
        CashWidget()
        NetWorthWidget()
        CashflowWidget()
    }
}
