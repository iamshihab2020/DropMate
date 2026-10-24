# DropMate design

DropMate is a household messenger that only works on your own Wi-Fi: chat, and drop files to the people
and devices in the room. Its users are families, often switching between English and Bangla, on a
Windows laptop and Android phones. The app's main job is to get this file to that person now.

## Tokens

| Name | Hex | Use |
|---|---|---|
| Drop | `#0A6CFF` | Primary actions, my message bubbles, links |
| Lagoon | `#00C9B1` | Online, success, transfer fill |
| Mist | `#EEF4FA` | Light background (cool, not cream) |
| Deepwater | `#0A1A2F` | Dark background, light-mode text |
| Harbor | `#13263F` | Dark surfaces |
| Signal | `#E5484D` | Errors, declined, destructive |

The gradient from Drop to Lagoon comes from the app icon. It appears in exactly two places: the online
ring around a person, and the liquid that fills a file card while it transfers.

**Type.** Hind Siliguri (Regular, Medium, SemiBold, Bold) is bundled so the app works offline and draws
Latin and Bangla in one family. Headlines are Bold at normal width. Anek Bangla's condensed display
style was tried and rejected by the client, so don't use condensed faces.

## Layout

- **Phone.** A "Here now" strip of people currently on your Wi-Fi sits above the conversation list.
  Adding a person is the last bubble in that strip.
- **Desktop (≥ 840 px).** Two panes: people on the left (340 px) and the open chat on the right. Every
  person row is also a drop target, so you can drag a file onto a name to send it.
- Text is left-aligned throughout. Only empty states and pairing are centred.

## Motion

- **Signature: liquid fill.** A file card fills with Lagoon water as bytes arrive. When the transfer
  finishes, the water settles and a check appears.
- **Online ripple.** Online people pulse softly, echoing the Wi-Fi arcs in the icon. This is the only
  animation nobody triggered.
- **New messages.** A message rises from the composer edge into place. History never animates.
- **Pairing.** The four check emojis pop in one after another.
- **Photos.** A finished photo or video replaces its water card with the picture itself; tapping it opens a black
  full-screen viewer (swipe on phones, arrows on desktop) via a Hero transition.
- **Buzz.** The buzz icon shakes when you send one; the person being buzzed sees a full-screen card with their
  caller's rippling avatar and one red Stop button.
- **Ticks.** Waiting (clock) → Received (double check) → Seen (double check in Lagoon). Only Seen is in colour.
- Everything above respects reduced motion (`MediaQuery.disableAnimations`).

## Not used

- All-caps labels.
- A shadow on every card.
- Gradient used as decoration anywhere other than the two places listed under Tokens.
