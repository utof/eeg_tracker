# Connecting the phone to the laptop by one scan

**Pair phone…** in the laptop tray's menu (or `python3 scripts/phone_link.py`), the phone's camera on the square
code it shows, **Open EEG Tracker**, **Connect**. That is the only scan: the pairing lasts (DECISIONS 675-677). The
tray keeps the laptop's side running whenever a phone is paired, the phone keeps Share on Wi-Fi on while a laptop is
paired, and each finds the other again by itself after a Wi-Fi drop, a restart or a new code. The owner's steps are
in `app/README.md` ("Share on Wi-Fi"); the choices and their alternatives in DECISIONS rows 530-539 and 675-677. This
page says what crosses the network and why it is safe enough for a home Wi-Fi.

## What happens

1. The laptop makes a **one-time code** (16 random bytes, 22 characters) and shows a QR code of
   `http://<laptop's Wi-Fi address>:8771/p?s=<code>`. The phone's token is not in it.
2. Any camera app opens that link in the browser. The laptop's page opens the app with
   `eegtracker://pair?h=<laptop>&p=8771&s=<code>&n=<laptop's name>` (as Chrome's `intent://` form, which names
   the app's package, so no other app can take the link).
3. The app asks **Connect to this laptop?** with the laptop's name and address. Nothing is sent before **Connect**.
4. The handshake, two HTTP requests to the address in the link:
   - `POST /link/hello {"v":1,"via":"code","nonce":N_phone}`. The laptop answers with its own nonce `N_laptop` and
     `HMAC-SHA256(code, "eeg-tracker link v1|laptop|code|N_phone|N_laptop")`. The app checks it: a device that does
     not know the code cannot make it, so the app stops there and **sends nothing more**.
   - `POST /link/finish` with `HMAC-SHA256(code, "eeg-tracker link v1|phone|code|N_laptop|N_phone")`, the Share on
     Wi-Fi port and the token. The laptop checks the proof, spends the code (it never works again) and answers with a
     new 32-byte **key** that the two keep.
5. The app switches Share on Wi-Fi on (if it was off) and remembers the laptop: address, port, key, name. The
   laptop remembers the phone in `_local/phone/link.json` (mode 600): the address it saw the requests come from, the
   port, the token and the key.
6. From then on, whenever Share on Wi-Fi starts, every 5 minutes while it is on, and as soon as the phone's Wi-Fi
   comes back or changes (Android's network callback, and the server's own look at its address every minute), the
   phone repeats the same two steps with `"via":"key"` and the key instead of the code. The laptop takes the phone's
   address from that connection, so a new address from the router is picked up at once, and a new token after
   **New code** too.

## Pairing that lasts (DECISIONS 675-677)

- **The phone**: while a laptop is paired, Share on Wi-Fi has no end time (not 12 hours, not 15 minutes after a
  night's Stop). It ends only when you switch it off or tap **Forget this laptop**. There is no notification for it
  (DECISIONS 678): between nights the phone answers while the app is open or a session runs, and during a night; in
  the background Android may freeze the app, so the laptop copies what it missed at the next app open, session or
  night (the phone tells the laptop where it is at each). Nothing is lost: the phone keeps every file. **New code** changes the token, not the pairing: the key stays, and
  the phone tells the laptop the new token itself.
- **The laptop**: the tray runs `phone_link.py --keep` whenever `_local/phone/link.json` holds a phone and no other
  copy answers on 127.0.0.1:8771 (a **Pair phone…** window, for instance). No window and no code; it listens on
  127.0.0.1 at once and on the laptop's home-network address once it has one (Wi-Fi off: it waits; back, or a new
  address: it listens there within 30 seconds). It copies the files and serves the live pages as before, writes
  what it says to `_local/phone/link-keep.log` (addresses and file names, never the token), is started again when
  it ends, and stops with the tray. **Pair phone…** then opens its page with a fresh code, for a new phone.
- **Forget the phone…** in the tray's menu deletes `link.json`; the kept link ends by itself, and the phone hears
  "no longer knows this phone" at its next announcement.

## Acknowledged receipt: moving raw recordings off the phone (DECISIONS 690-699)

7. After each copy pass the laptop hashes every finished copy the phone lists and has not acked yet **from its own
   disk** (never from its index of hashes; a copy it packed as `.f32.xz` is unpacked to hash it), at most 4 GB a pass,
   oldest first. Before any hashing an empty ack asks whether the phone takes acks from this key at all.
8. Where its hash equals the phone's (for a packed `.f32.gz`, the `original`'s), it sends
   `POST /ack` to the phone's Share on Wi-Fi port with the token, `{"v":1,"files":[{"path","sha256"}]}` and the header
   `X-Eeg-Ack: HMAC-SHA256(key, "eeg-tracker ack v1|" + body)` with the pairing's key (vectors in
   `app/test/fixtures/phone_ack.json`). The phone refuses the whole request without a pairing (403 `not paired`) or
   with a wrong proof (403), then checks each file on its own: an ack is kept only for a shared file that rests (not
   written in the last 20 s) and holds exactly those bytes now (`refused`: `different bytes`, `not on the phone`,
   `still being written`, `not a file the phone shares`). Kept acks go to `files/transfer/acks.json` (never exported or
   shared) and `/files` marks each acked file `"acked": true`, so a laptop that lost its notes does not hash it twice.
9. The phone decides alone what leaves it (the Storage page, `app/README.md` "Storage"): while a laptop is paired, a
   raw recording 3 days after its ack, never anything not acked as it is now, never the statistics. A set that left it
   leaves `<stamp>.removed.json`, which the laptop copies like any file and checks against what it holds.

The laptop never deletes anything; `_local/phone/acks.jsonl` has one line per ack sent and taken.

## Who can do what

- **The code** works once and for 5 minutes. It is shown on the laptop's screen and in the phone's browser history;
  someone who photographs it could pair *their* device with the laptop within those minutes (the laptop window says
  "Paired with the phone at <address>", so it would show). They learn nothing about the owner's phone.
- **The phone's token** goes only to the laptop at the address in the link, and only after that laptop proved it
  knows the code (or, later, the key). A device that takes over the laptop's old address gets a hello and nothing
  else.
- **Only the local network**: the app accepts a laptop address only in 10.x, 172.16-31.x, 192.168.x, 169.254.x (or
  the phone itself), never a name and never an internet address. The laptop listens on its Wi-Fi address and on
  127.0.0.1 only (never on all interfaces) and answers local-network clients only. Its own page with the code
  (`http://127.0.0.1:8771/`) and the live pages (`http://localhost:8770/`) answer this laptop only.
- **Not encrypted**: plain HTTP, like Share on Wi-Fi itself (DECISIONS row 225). The proofs keep the code and the
  key off the wire, but the token and the data cross the Wi-Fi as they always did. Home Wi-Fi only.
- **Acks**: only the paired laptop can make the phone delete anything, and only what it vouches it holds byte for byte:
  a proof made with the pairing's key covers each request's body, and every file is checked against the phone's own
  bytes. A replayed ack changes nothing (the same file, the same bytes). Someone on the Wi-Fi with the token but not the
  key can read files (as before) but cannot ack. Forgetting the laptop stops the automatic deleting (it runs only
  while a laptop is paired).
- **Forgetting**: **Forget this laptop** on the phone's Share sheet stops the phone telling it anything (and brings
  back sharing's end time); **New code** on the sheet changes the token, which a paired laptop is told by the key, so
  to shut a laptop out tap **Forget this laptop** first. **Forget the phone…** in the tray (or deleting
  `_local/phone/link.json`) makes the laptop forget the phone. Pairing again replaces the key on both sides.

## Known limits

- A VPN on the phone that sends local traffic into its tunnel stops the phone's two requests; the laptop's copies,
  which go the other way, may still work. Turn the VPN off for the scan, or let it bypass the local network.
- The phone and the laptop must be on the same network. If the **laptop's** address changes (a router hands out the
  same one for days as a rule), the phone's announcements go to the old one: the laptop still reaches the phone at
  its known address, so copying and the tray's headband line go on, but a new phone address or token after that
  needs one new scan.
- Between nights the laptop reaches the phone only while the app runs (row 678), so the tray's headband line shows
  "not reachable" while the app sleeps in the background with no session.
- One phone per laptop: a new pairing replaces the old one.
