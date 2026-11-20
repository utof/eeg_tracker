# Share on Wi-Fi and the paired laptop

## What it does

Lets your own laptop copy the recordings and watch the live signal over Wi-Fi. While a laptop is paired, the phone
shares only on your home Wi-Fi (or one you allow for 12 hours), and after it checks with the laptop again it may
remove old raw recordings that the laptop holds.

## Evidence for this headband: some

The safeguards follow well-known published practice, but the link is not encrypted yet: on your home Wi-Fi with a
strong WPA3 password it is safe enough; on a shared Wi-Fi others can read what is copied while you allow it.

## What the research says

- Plain (unencrypted) web traffic can be read by anyone who can watch the network, and changed by someone who can
  redirect it ([OWASP MASWE-0050](https://mas.owasp.org/MASWE/MASVS-NETWORK/MASWE-0050/),
  [Android cleartext guidance](https://developer.android.com/privacy-and-security/risks/cleartext-communications)).
- On a Wi-Fi with one shared password (WPA2-Personal), anyone who knows the password can decode other devices'
  traffic ([Wireshark](https://www.wireshark.org/docs/wsug_html_chunked/Ch80211Keys.html)). WPA3-SAE stops that, but
  a mixed WPA2/WPA3 setting lets an attacker fall back to WPA2
  ([HPE Aruba](https://arubanetworking.hpe.com/techdocs/aos/wifi-design-deploy/security/modes/wpa3-personal/)).
- Home Assistant's phone app uses plain web links only on the home Wi-Fi you name, to keep its password off public
  networks ([Home Assistant](https://companion.home-assistant.io/docs/getting_started/connection-security-level)).
  This app does the same: away from home it shares nothing unless you allow it.
- A web page can reach programs on your own computer by pointing its name at it ("DNS rebinding"); checking the
  `Host` and `Origin` of each request is the standard fix
  ([MCP advisory](https://github.com/modelcontextprotocol/typescript-sdk/security/advisories/GHSA-w48q-cv73-mx4w)).
- A browser never sends the part of a link after `#`
  ([RFC 3986, section 3.5](https://www.rfc-editor.org/rfc/rfc3986#section-3.5)), so a code there stays between the
  laptop's screen, the camera and the app.
- The lasting fix is encryption with certificates both devices check against each other, as Syncthing does
  ([Syncthing protocol](https://docs.syncthing.net/specs/bep-v1.html)).

## Where the data does not support it

- Nothing here is encrypted. Someone who controls your home Wi-Fi at the moment you scan the laptop's code could
  still step in between the two devices.
- The phone cannot read your Wi-Fi's name without the location permission, which this app does not ask for. It
  learns that a network is home from the paired laptop, which recognises its own router.

## How the app uses this

- Pairing: one scan. The one-time code never crosses the Wi-Fi; both devices work out the same key from it, so the
  key is never sent either.
- After pairing the laptop signs every request with that key (with the time and a number used once, so a copied
  request cannot be sent again), and the phone answers with a proof of the same key. The phone's code is not used.
- Away from home the phone shares nothing until you tap Share here; that lasts 12 hours and only on that Wi-Fi.
- The Share on Wi-Fi sheet shows where it shares and when the laptop last copied, and cannot be screenshotted. The
  laptop's tray shows the same.
- Before the phone removes a raw recording by itself, it asks the laptop to prove it still holds those exact bytes
  (random parts of the file and a fresh number). No proof right then: nothing is removed.
- The laptop's own pages answer this laptop only. Logs keep no network addresses.

## Sources

- [OWASP MASWE-0050](https://mas.owasp.org/MASWE/MASVS-NETWORK/MASWE-0050/)
- [Android: cleartext communications](https://developer.android.com/privacy-and-security/risks/cleartext-communications)
- [Wireshark: Wi-Fi decryption](https://www.wireshark.org/docs/wsug_html_chunked/Ch80211Keys.html)
- [HPE Aruba: WPA3-Personal](https://arubanetworking.hpe.com/techdocs/aos/wifi-design-deploy/security/modes/wpa3-personal/)
- [Home Assistant: connection security level](https://companion.home-assistant.io/docs/getting_started/connection-security-level)
- [MCP TypeScript SDK advisory GHSA-w48q-cv73-mx4w](https://github.com/modelcontextprotocol/typescript-sdk/security/advisories/GHSA-w48q-cv73-mx4w)
- [RFC 3986](https://www.rfc-editor.org/rfc/rfc3986#section-3.5)
- [Syncthing Block Exchange Protocol v1](https://docs.syncthing.net/specs/bep-v1.html)

## Libraries and models

- HMAC-SHA256 from Dart's [crypto](https://pub.dev/packages/crypto) package (BSD-3-Clause) and Python's standard
  library.

Checked: 2026-11-20
