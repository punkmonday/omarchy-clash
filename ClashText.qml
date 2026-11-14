import QtQuick
import qs.Commons

// Local Text with markup parsing off. Plugin-owned displays bind this instead
// of plain Text so proxy names, hosts, and API errors — all untrusted — can
// never be reinterpreted as rich text.
Text {
  textFormat: Text.PlainText
  color: Commons.Color.foreground
  font.family: Style.font.family
  font.pixelSize: Style.font.body
}
