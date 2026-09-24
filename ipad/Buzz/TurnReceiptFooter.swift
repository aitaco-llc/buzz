import BuzzCore
import SwiftUI

/// What one agent turn ran on and what it spent, under the last message that
/// turn published. The counts are the turn's, not any one message's, so this
/// appears once per turn however many messages the turn produced.
struct TurnReceiptFooter: View {
  let receipt: TurnReceipt

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Image(systemName: "cpu")
      Text(receipt.summary)
    }
    .font(.caption).foregroundStyle(.secondary)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(receipt.accessibilityDescription)
    .accessibilityIdentifier("turn-receipt-\(receipt.id)")
  }
}
