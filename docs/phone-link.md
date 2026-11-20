# Connecting the phone to the laptop by one scan

**Pair phone…** in the laptop tray's menu (or `python3 scripts/phone_link.py`), the phone's camera on the square
code it shows, **Open EEG Tracker**, **Connect**. That is the only scan: the pairing lasts (DECISIONS 675-677). The
tray keeps the laptop's side running whenever a phone is paired, the phone keeps Share on Wi-Fi on while a laptop is
paired, and the laptop finds the phone again by itself after a Wi-Fi drop, a restart or a new address. The owner's
steps are in `app/README.md` ("Share on Wi-Fi"); the choices and their alternatives in DECISIONS rows 530-539,
675-677 and 750-759 (the second version of the link, after the security review of 2026-11-20). This page says what
crosses the network and why it is safe enough for a home Wi-Fi.

## What happens

1. The laptop makes a **one-time code** (16 random bytes, 22 characters) and shows a QR code of
   `http://<laptop's Wi-Fi address>:8771/p#s=<code>`. The code sits after `#`, which a browser never sends: the
   laptop's page reads it in the browser and opens the app with `eegtracker://pair?h=<laptop>&p=8771&s=<code>&n=<name>`
   (as Chrome's `intent://` form, which names the app's package, so no other app can take the link). Only while a
   code is shown does the laptop listen on its Wi-Fi address; otherwise on 127.0.0.1 only.
2. The app asks **Connect to this laptop?** with the laptop's name and address. Nothing is sent before **Connect**.
3. The handshake, two HTTP requests to the address in the link (`app/lib/share/auth.dart`,
   `scripts/phone_auth.py`; test vectors in `app/test/fixtures/phone_link.json`):
   - `POST /link/hello {"v":2,"nonce":N_phone}`. The laptop answers with its own nonce `N_laptop`, its name and
     `HMAC-SHA256(code, "eeg-tracker link v2|laptop|N_phone|N_laptop")`. The app checks it: a device that does not
     know the code cannot make it, so the app stops there and **sends nothing more**.
   - `POST /link/finish {"v":2,"nonce":N_laptop,"proof":…,"port":<Share on Wi-Fi port>}` with
     `HMAC-SHA256(code, "eeg-tracker link v2|phone|N_laptop|N_phone")`. The laptop checks it, spends the code (it never
     works again) and answers with its name and a confirmation made with the new key.
   - Both sides work the **key** out by themselves: `HMAC-SHA256(code, "eeg-tracker key v2|N_phone|N_laptop")`. The
     key, the code and the phone's token never cross the Wi-Fi.
4. The app switches Share on Wi-Fi on (if it was off) and remembers the laptop: address, port, key, name. The laptop
   keeps `_local/phone/link.json` (mode 600): the key, the phone's address and port, and **home**: its router's
   address and hardware address at the moment of pairing (`phone_link.home_id`, from `/proc/net/route` and
   `/proc/net/arp`). The network you pair on is your home Wi-Fi.
5. From then on the laptop asks; the phone never announces itself. Every request of the laptop is **signed** with the
   key (below) and every answer of the phone proves the key too, so neither side talks to a device that only took the
   other's address. The laptop tries the phone's last address; at home, when nothing answers there, it looks round its
   own /24 network at most every 10 minutes and keeps the address whose answer proves the key (`find_phone`).

## Signed requests (DECISIONS 751, 755)

Each request of the paired laptop carries `X-Eeg-Time` (ms since 1970), `X-Eeg-Nonce` (16 random bytes, base64url),
`X-Eeg-Home` (`1` when the laptop sees its home router now, else `0`) and
`X-Eeg-Sign = HMAC-SHA256(key, "eeg-tracker request v2|METHOD|time|nonce|home|sha256(body)|sha256(path)|sha256(query)")`.
The phone takes it within 5 minutes of its own clock, never the same nonce twice (it remembers them for 10 minutes),
and answers with `X-Eeg-Reply = HMAC-SHA256(key, "eeg-tracker reply v2|nonce")`; the laptop drops an answer without it.
Errors: 401 `not paired`, `signature`, `replayed`, or `clock` (with the phone's `phone_ms`).

`POST /work`, `POST /marker`, `POST /ack`, `GET`/`POST /recheck` and `GET /who` take only signed requests. The token
(the code on the Share sheet) still reads files and the live signal, for `scripts/pull_phone.py` and
`scripts/page_server.py` run by hand, only in the `Authorization: Bearer` header (never `?token=`, never in a link).
Ten wrong tries in a minute from one address make it wait a minute (429); the phone holds at most 16 connections from
one address and 32 in all.

## Where the phone shares (DECISIONS 752)

Plain HTTP is safe enough on your own WPA2/WPA3 Wi-Fi, not on a shared one. A paired phone shares only:

- **at home**: the paired laptop said so (a signed request with `X-Eeg-Home: 1` from the local network). The phone
  cannot read the Wi-Fi's name itself without the location permission, which this app does not ask for; it trusts the
  laptop, which recognises its own router. It lasts 30 minutes after the laptop last said so (the tray looks every 45
  seconds and copies every 2 minutes, so at home it does not run out), and Android's word that the network changed
  ends it at once: another Wi-Fi may use the same addresses;
- **here, for 12 hours**: **Share here for 12 hours** on the Share sheet allows the Wi-Fi the phone is on now, until
  then or until it changes networks (**Stop sharing here** ends it);
- otherwise it is **paused**: 403 `not sharing on this Wi-Fi` to everyone on the network, the laptop too. A USB cable
  (`adb forward`, the phone itself) always works.

There is no notification for it (the owner's choice, DECISIONS 678). The Share sheet and the line under the switch say
which of the three it is and when the laptop last copied ("Last copied by my-laptop at 14:05"); the laptop tray's
menu says the same ("Phone: sharing on its home Wi-Fi · copied 14:05", or "on another Wi-Fi: sharing paused there").
An unpaired phone shares as before: anyone on the Wi-Fi with the code, for 12 hours.

## Pairing that lasts (DECISIONS 675-677)

- **The phone**: while a laptop is paired, Share on Wi-Fi has no end time. It ends only when you switch it off or tap
  **Forget this laptop**. Between nights the phone answers while the app is open or a session runs, and during a
  night; in the background Android may freeze the app, so the laptop copies what it missed at the next app open,
  session or night. Nothing is lost: the phone keeps every file. **New code** changes the token only; the paired
  laptop does not use it.
- **The laptop**: the tray runs `phone_link.py --keep` whenever `_local/phone/link.json` holds a phone and no other
  copy answers on 127.0.0.1:8771. It listens on 127.0.0.1 only (its page and **Pair phone…**, a POST from that page,
  which then listens on the Wi-Fi for that code's 5 minutes), copies the files, serves the live pages on
  `http://localhost:8770/`, and writes what it says to `_local/phone/link-keep.log` (file names and counts, never an
  address, the token or the key).
- **Forget the phone…** in the tray's menu deletes `link.json`; the kept link ends by itself.

## Updating from the first version (re-pair once)

Pairings made before this version (`link.json` `version` 1, which kept the phone's token; on the phone a laptop
without the new key) are not used any more: their key had crossed the Wi-Fi. The app's line says "Paired with
<laptop> before this update: pair once more", the tray says "paired the old way: Pair phone… once more", and the
phone deletes nothing by itself until then. One scan of a new code pairs them the new way. Update the laptop's scripts
with the app: a laptop of the first version answers the new app's hello with an error, and the new laptop answers an
old app with 400 `old app`.

## Acknowledged receipt: moving raw recordings off the phone (DECISIONS 690-699, 756)

6. After each copy pass the laptop hashes every finished copy the phone lists and has not acked yet **from its own
   disk** (a copy it packed as `.f32.xz` is unpacked to hash it), at most 4 GB a pass, oldest first.
7. Where its hash equals the phone's (for a packed `.f32.gz`, the `original`'s), it sends a signed
   `POST /ack {"v":1,"files":[{"path","sha256"}]}`. The phone checks each file on its own: an ack is kept only for a
   shared file that rests (not written in the last 20 s) and holds exactly those bytes now. Kept acks go to
   `files/transfer/acks.json` (never exported or shared).
8. **The check right before deleting.** An ack says the laptop held the bytes then. When the Storage page's keep time
   (3 days after the ack by default) is up, the phone asks again first:
   - it writes a question per file into `files/transfer/recheck.json`: a fresh nonce and 8 random 4 KB ranges (all of
     a file up to 32 KB) of the file's plain bytes;
   - the laptop reads them (signed `GET /recheck`) at its next pass and answers (signed `POST /recheck`) with
     `HMAC-SHA256(key, "eeg-tracker recheck v1|sha256(path)|nonce|size|start+length,…|" + those bytes)` of **its own
     copy**, or `"missing": true` when it does not hold it as acked;
   - while a question is open the phone does not hand that file out (409), so the answer cannot be made from the
     phone's own copy; a hash, even one the phone lists itself, proves nothing here;
   - the phone works the same HMAC out from its own bytes. Only a proof from the last 15 minutes lets the file go; no
     proof, nothing is deleted. A laptop that lost the file or holds other bytes loses the ack: the file stays, and
     the laptop copies and acks it again.
9. The phone decides alone what leaves it (`app/README.md` "Storage"): while a laptop is paired, a raw recording 3
   days after its ack and after that fresh proof, never anything not acked, never the statistics. A set that left it
   leaves `<stamp>.removed.json`, which the laptop copies like any file and checks against what it holds.

The laptop never deletes anything; `_local/phone/acks.jsonl` has one line per ack (no addresses).

## The phone sends by itself (DECISIONS 840-849)

The copy above needs the laptop to reach the phone, which works while a recording or a session runs and while the app
is open. For the rest of the day the direction is turned round: the phone opens the connection. No server, no
notification.

- **When.** Android's own scheduler runs a short job about every 15 minutes while the phone is on Wi-Fi (Android
  picks the moment; 15 minutes is the shortest it allows), and once more a few seconds after a recording or a session
  ends. It also runs during a recording, so the laptop's copy grows even if nothing can reach the phone's port. Only
  with Share on Wi-Fi on and a laptop paired. The job survives a restart of the phone.
- **Where.** Only on the home Wi-Fi, by the same rule as above asked from the phone's side: the phone talks only to an
  address inside the Wi-Fi network it is on, the laptop must prove the pairing's key, and the laptop must say it is on
  the network where it paired (its router). Before that proof the phone says nothing about its files. The phone looks
  for the laptop where its signed requests last came from, then where it was at pairing, then (at most every 2 hours)
  around the home network.
- **How.** Four signed `POST`s to the laptop's receiver (`scripts/push_receiver.py`, inside `phone_link.py --keep`,
  port 8772):
  1. `/push/hello`: the laptop proves the key and says `home`.
  2. `/push/begin`: the phone's file list (the one `GET /files` gives) and its open questions before deleting. The
     laptop answers which bytes it lacks: `want: [{path, from, have}]`.
  3. `/push/chunk?s=&p=&at=`: those bytes, at most 4 MB a request, in order.
  4. `/push/commit`: the laptop files what arrived with the same code and rules as its own copy pass (a temporary
     name, the SHA-256 check, then the rename; partial copies of growing files; `replaced/`; `pull-state.json`) and
     answers with its acks and its proofs, which the phone takes exactly as `POST /ack` and `POST /recheck`.
- **Signatures.** Each request carries `X-Eeg-Time`, `X-Eeg-Nonce` and `X-Eeg-Sign` =
  `HMAC-SHA256(key, "eeg-tracker push v1|METHOD|time|nonce|sha256(body)|sha256(path)|sha256(query)")`; each answer
  carries `X-Eeg-Reply` = `HMAC-SHA256(key, "eeg-tracker push reply v1|nonce|sha256(answer)")`, so the phone knows the
  wishes and the acks are the paired laptop's, unchanged. Another tag than the laptop's own requests, so neither
  side's requests pass for the other's. Vectors: `app/test/fixtures/phone_link.json` (`push`).
- **Cut off anywhere, nothing is lost.** Uploaded bytes wait in `_local/phone/push-inbox/` (names made from a hash,
  never the phone's file names) until a commit; the next push goes on where this one stopped. Nothing half-made
  appears in the real folders.
- **Deleting stays as careful.** A file the phone is asking about before deleting is never sent in a push, so the
  laptop's proof can only come from its own copy.
- **The two ways cannot clash.** The laptop's own copy pass and a push's commit are the same code under one lock
  (`flock` on `_local/phone/`), with the same names and the same state file: a file half-copied one way is finished
  the other way, never twice.
- **What the receiver refuses** (it is the one laptop port that listens on the home network, and only while the
  laptop is there): anything but those four `POST`s (no listing, nothing is ever sent out), a missing or too big
  `Content-Length` before a byte is read, a wrong or reused signature, a time more than 5 minutes off, ten wrong tries
  a minute from one address, an address outside the local network, a chunk for a file it did not ask for or past the
  listed size, a wrong `Host`.

## Who can do what

- **The code** works once and for 5 minutes, and only from the laptop's screen to the phone's camera (it is never
  sent, and the browser never sends what follows `#`). Someone who photographs it could pair *their* device with the
  laptop within those minutes (the laptop window would show it).
- **The key** never crosses the Wi-Fi. Someone watching the Wi-Fi during pairing sees two nonces and two proofs; to
  get the key they would need the code too.
- **The token** is only for tools run by hand and for the cable; the paired laptop never sends it. It is never in a
  link or the Share sheet's QR code, and Android keeps the Share sheet out of screenshots and the recent-apps preview.
- **Changing things on the phone** (`/work`, `/marker`, acks, the check before deleting) takes the key: a copied
  request is refused (its nonce was used), and a request changed on the way fails its signature.
- **Only the local network**: the app accepts a laptop address only in 10.x, 172.16-31.x, 192.168.x, 169.254.x (or
  the phone itself), never a name and never an internet address. The laptop's own servers (`phone_link.py`'s page,
  `page_server.py`, the recorder hub, the tray's) listen on 127.0.0.1 and check `Host` and `Origin`, so a web page in
  the laptop's browser cannot reach them by another name (DNS rebinding) or post to them.
- **Not encrypted**: plain HTTP. Someone on the same Wi-Fi can read what is copied and the live signal while the phone
  shares there. Someone who controls the Wi-Fi at the moment of the scan could still step in between. Home Wi-Fi only,
  with a strong WPA3 (or WPA2) password.
- **Logs** keep no network addresses (the app writes them as `#.#.#.#`; the laptop's logs say "the paired phone").
- **Forgetting**: **Forget this laptop** on the phone refuses its signed requests from then on and stops the automatic
  deleting. **Forget the phone…** in the tray makes the laptop forget the phone. Pairing again replaces the key.

## Known limits

- A VPN on the phone that sends local traffic into its tunnel stops pairing. Turn it off for the scan, or let it
  bypass the local network.
- The phone and the laptop must be on the same network. At home the laptop finds a phone with a new address within 10
  minutes; elsewhere (Share here) only at the last address it knew.
- Between nights the laptop reaches the phone only while the app runs (row 678), so the tray's headband line shows
  "not reachable" while the app sleeps in the background with no session. The files still arrive: the phone sends them
  by itself (above), and the tray says when.
- Android decides when a scheduled job runs. With the phone unused for hours (Doze) it may wait longer than 15
  minutes; the job after a recording usually runs within seconds. If the phone's battery saver or the maker's own
  limits hold the app back, the files arrive at the next app open instead.
- When port 8765 on the phone is held by something else, the app serves on 8766, 8767 or 8768; the laptop looks there
  by itself, and the app's log says what held 8765.
- A home with two routers on one network, or a laptop on a cable to another router, may not be recognised as home:
  **Share here** covers it for 12 hours at a time.
- One phone per laptop: a new pairing replaces the old one.
- Android 17 asks for "Nearby devices" (local network) once the app targets it; the app asks when sharing is switched
  on or a pairing starts (DECISIONS 758). Refused: nothing is shared or paired, and the line says where to allow it.
- Encryption (TLS with certificates the two pin to each other) is the lasting fix; DECISIONS 759 has what was checked.
