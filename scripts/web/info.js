// "i" buttons: addInfo(element, id) puts a small round "i" right after an element's text; it opens a dialog with
// the evidence note docs/evidence/<id>.md (title, grade badge, text), converted into evidence.js by
// scripts/evidence_to_js.py. Esc, the close button or a tap outside closes it.
//
// Placement: for a block element (a heading or label) the button goes at the end of its content, on the same
// line as its text; for an inline element (span, b) it goes right after the element. Use an element whose content
// the page does not rewrite, or the button is lost on the next update.
//
// Port note: the phone app bundles the same .md files as assets and shows them in its own sheet; nothing here
// needs porting except the placement idea (an "i" next to each feature's title).
import { EVIDENCE } from './evidence.js';

const GRADE_WORD = { strong: 'strong', some: 'some', weak: 'weak', none: 'none' };
const CSS = `
.ev-i{all:unset;box-sizing:border-box;-webkit-tap-highlight-color:transparent;display:inline-flex;align-items:center;justify-content:center;
 width:24px;height:24px;margin:0 0 0 8px;border-radius:50%;border:1px solid #4a5157;background:#1d2125;
 color:#c9c6bf;font:italic 600 14px/1 Georgia,'Times New Roman',serif;vertical-align:middle;cursor:pointer;
 flex:none;letter-spacing:0;text-transform:none}
.ev-i:hover{border-color:#8ab4f8;color:#e8e6e1}
.ev-i:focus-visible{outline:2px solid #8ab4f8;outline-offset:2px}
.ev-dialog{box-sizing:border-box;width:min(640px,calc(100vw - 20px));max-width:calc(100vw - 20px);
 max-height:min(88vh,900px);padding:0;
 border:1px solid #3a4046;border-radius:14px;background:#181b1e;color:#e8e6e1;
 font:16px/1.5 system-ui,sans-serif;text-align:left;font-weight:400;letter-spacing:0}
.ev-dialog::backdrop{background:rgba(0,0,0,.65)}
.ev-wrap{max-height:inherit;overflow-y:auto;overscroll-behavior:contain;padding:0 18px 18px}
.ev-head{position:sticky;top:0;display:flex;gap:12px;align-items:flex-start;justify-content:space-between;
 padding:16px 0 10px;background:#181b1e}
.ev-head h2{margin:0;font-size:19px;line-height:1.3;font-weight:600}
.ev-x{all:unset;box-sizing:border-box;flex:none;display:inline-flex;align-items:center;justify-content:center;
 min-width:44px;height:36px;padding:0 12px;border-radius:10px;border:1px solid #3a4046;background:#1d2125;
 color:#e8e6e1;font:14px system-ui,sans-serif;cursor:pointer}
.ev-x:focus-visible{outline:2px solid #8ab4f8;outline-offset:2px}
.ev-grade{margin:0 0 4px;color:#9aa0a6;font-size:14px}
.ev-badge{display:inline-block;margin-left:6px;padding:1px 10px;border-radius:99px;font-weight:600;color:#101214}
.ev-badge.strong{background:#7fd1a0}.ev-badge.some{background:#8ab4f8}.ev-badge.weak{background:#e6c35c}
.ev-badge.none{background:#9aa0a6}
.ev-body h3{margin:18px 0 6px;font-size:15px;font-weight:600;color:#c9c6bf}
.ev-body h4{margin:12px 0 4px;font-size:14px;font-weight:600;color:#c9c6bf}
.ev-body p{margin:6px 0}.ev-body ul{margin:6px 0;padding-left:20px}.ev-body li{margin:4px 0}
.ev-body a{color:#8ab4f8;overflow-wrap:anywhere}.ev-body code{font-size:14px;color:#c9c6bf}
`;

let dialog = null;
let opener = null;

function build() {
  const style = document.createElement('style');
  style.textContent = CSS;
  document.head.appendChild(style);
  dialog = document.createElement('dialog');
  dialog.className = 'ev-dialog';
  dialog.setAttribute('aria-labelledby', 'ev-title');
  dialog.innerHTML = '<div class="ev-wrap"><div class="ev-head"><h2 id="ev-title"></h2>' +
    '<button type="button" class="ev-x" autofocus>Close</button></div>' +
    '<p class="ev-grade">Evidence:<span class="ev-badge"></span></p>' +
    '<div class="ev-body"></div></div>';
  dialog.querySelector('.ev-x').addEventListener('click', () => dialog.close());
  // a tap on the dimmed backdrop lands on the dialog itself (the content fills it), so it closes the note
  dialog.addEventListener('click', (e) => { if (e.target === dialog) dialog.close(); });
  dialog.addEventListener('close', () => { if (opener && opener.isConnected) opener.focus(); opener = null; });
  document.body.appendChild(dialog);
}

/** Opens the note `id` in a modal dialog; `from` gets the focus back when it closes. */
export function openInfo(id, from = null) {
  const note = EVIDENCE[id];
  if (!note) throw new Error(`no evidence note "${id}"`);
  if (!dialog) build();
  dialog.querySelector('#ev-title').textContent = note.title;
  const badge = dialog.querySelector('.ev-badge');
  badge.className = `ev-badge ${note.grade}`;
  badge.textContent = GRADE_WORD[note.grade] ?? note.grade;
  dialog.querySelector('.ev-body').innerHTML = note.html; // built from the notes by evidence_to_js.py, all escaped
  opener = from;
  if (dialog.open) dialog.close();
  dialog.showModal();
  dialog.querySelector('.ev-wrap').scrollTop = 0;
}

/** Puts a round "i" button after `element`'s text that opens the evidence note `id`; returns the button. */
export function addInfo(element, id) {
  const note = EVIDENCE[id];
  if (!note) throw new Error(`no evidence note "${id}"`);
  if (!element) throw new Error(`addInfo("${id}"): no element`);
  const b = document.createElement('button');
  b.type = 'button';
  b.className = 'ev-i';
  b.textContent = 'i';
  b.dataset.evidence = id;
  b.title = 'What the research says';
  b.setAttribute('aria-label', `What the research says: ${note.title}`);
  b.setAttribute('aria-haspopup', 'dialog');
  b.addEventListener('click', (e) => { e.preventDefault(); e.stopPropagation(); openInfo(id, b); });
  if (!dialog) build();
  const inline = getComputedStyle(element).display.startsWith('inline');
  if (inline) element.after(b); else element.append(b);
  return b;
}
