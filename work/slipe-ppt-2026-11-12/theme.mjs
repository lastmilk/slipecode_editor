// Design tokens + shared primitives for the SLIPE strategy deck.
// Route: PptxGenJS, native text / shapes / tables / charts only.
import { addSingleLineToken } from "/data/user/plugins/trae-remote-official/jingmei-ppt/1.0.0/skills/jingmei-ppt/scripts/pptx-text-guards.mjs";

export const W = 13.333;
export const H = 7.5;
export const M = 0.62;
export const CW = W - M * 2;

// Role-based palette. Lime (#DFFF3F) is reserved for decisions and gates.
export const C = {
  bg: "111210",
  panel: "191B17",
  panel2: "1F221C",
  ink: "F2F4EC",
  muted: "A8AEA1",
  dim: "7B8276",
  rule: "383D34",
  ruleSoft: "2A2E26",
  accent: "6D88FF",
  accentDeep: "3E4A6B",
  accentSoft: "9FB0FF",
  pop: "DFFF3F",
};

export const F = {
  cjk: "Noto Sans CJK SC",
  mono: "Noto Sans Mono",
};

export const T = {
  cover: 46,
  claim: 24,
  body: 10.5,
  small: 9,
  micro: 7.4,
  source: 7,
  table: 8.6,
};

export const REG = [];
const warnings = [];

export function warn(message) {
  warnings.push(message);
  console.warn(`[layout] ${message}`);
}
export function getWarnings() {
  return warnings;
}

function noteBox(kind, label, x, y, w, h, page) {
  if (x < -0.001 || y < -0.001 || x + w > W + 0.001 || y + h > H + 0.001) {
    warn(`page ${page}: ${kind} "${label}" out of canvas (${x.toFixed(2)},${y.toFixed(2)},${w.toFixed(2)},${h.toFixed(2)})`);
  }
}

function charEm(ch) {
  if (ch === " ") return 0.3;
  const code = ch.codePointAt(0);
  if (code >= 0x2e80) return 1.0;
  if (/[A-Z]/.test(ch)) return 0.66;
  if (/[a-z]/.test(ch)) return 0.54;
  if (/[0-9]/.test(ch)) return 0.6;
  if (/[，。；：、！？“”‘’（）【】—…·]/.test(ch)) return 1.0;
  return 0.42;
}

export function wrapLines(str, fs, wIn, inset = 0.02) {
  const usable = (wIn - inset * 2) * 72;
  let total = 0;
  for (const para of String(str).split("\n")) {
    let lines = 1;
    let cur = 0;
    for (const ch of para) {
      const cw = charEm(ch) * fs;
      if (cur + cw > usable && cur > 0) {
        lines += 1;
        cur = cw;
      } else {
        cur += cw;
      }
    }
    total += lines;
  }
  return total;
}

// Native text box with a conservative fit check.
export function text(slide, content, o) {
  const {
    x, y, w, h,
    fs = T.body,
    color = C.ink,
    bold = false,
    font = F.cjk,
    align = "left",
    valign = "top",
    lh = Math.round(fs * 1.4 * 10) / 10,
    charSpacing,
    italic = false,
    fitCheck = true,
    label,
    page = 0,
  } = o;
  const plain = Array.isArray(content) ? content.map((r) => r.text).join("") : String(content);
  const lines = wrapLines(plain, fs, w);
  const need = (lines * lh) / 72 + 0.01;
  if (fitCheck && need > h + 0.015) {
    warn(`page ${page}: text overflow "${plain.slice(0, 26)}" needs ${need.toFixed(2)}in > ${h.toFixed(2)}in (${lines} lines @${fs}pt)`);
  }
  noteBox("text", plain.slice(0, 20), x, y, w, h, page);
  slide.addText(content, {
    x, y, w, h,
    fontFace: font,
    fontSize: fs,
    color,
    bold,
    italic,
    align,
    valign,
    margin: 0,
    lineSpacing: lh,
    charSpacing,
    wrap: true,
    vert: "horz",
  });
}

// Single-line token primitive: wraps the provided guard helper.
export function token(slide, value, o) {
  const { x, y, w, h, fs = 10, color = C.ink, bold = false, font = F.mono, align = "left", page = 0 } = o;
  noteBox("token", String(value), x, y, w, h, page);
  return addSingleLineToken(slide, value, {
    x, y, w, h,
    fontFace: font,
    fontSize: fs,
    bold,
    color,
    align,
    valign: "mid",
    warn: (m) => warn(`page ${page}: ${m}`),
  });
}

export function rect(slide, x, y, w, h, { fill = C.panel, line = C.rule, linePt = 0.6 } = {}) {
  slide.addShape("rect", {
    x, y, w, h,
    fill: { color: fill },
    line: line ? { color: line, width: linePt } : { type: "none" },
  });
}

export function hairline(slide, x, y, w, { color = C.rule, pt = 0.75 } = {}) {
  slide.addShape("line", { x, y, w, h: 0, line: { color, width: pt } });
}

// Panel with optional semantic edge rule (accent = structure, lime = gate/decision).
export function panel(slide, x, y, w, h, { topRule, leftRule, fill = C.panel, line = C.rule, page = 0 } = {}) {
  rect(slide, x, y, w, h, { fill, line });
  if (topRule) rect(slide, x, y, w, 0.035, { fill: topRule, line: null });
  if (leftRule) rect(slide, x, y, 0.04, h, { fill: leftRule, line: null });
  if (topRule || leftRule) noteBox("panel", "panel", x, y, w, h, page);
}

export function kicker(slide, value, o) {
  const { x, y, w, color = C.accent, fs = 7.6, align = "left", page = 0 } = o;
  token(slide, value, { x, y, w, h: 0.18, fs, color, align, page });
}

// Numbered / bulleted evidence list built from many small boxes for exact rhythm.
export function bulletList(slide, items, o) {
  const {
    x, y, w,
    gap = 0.08,
    fs = 9,
    lh = Math.round(fs * 1.42 * 10) / 10,
    color = C.muted,
    marker = "dot",
    markerColor = C.accent,
    lineColor = null,
    page = 0,
  } = o;
  let cy = y;
  for (const item of items) {
    const plain = Array.isArray(item) ? item.map((r) => r.text).join("") : item;
    const lines = wrapLines(plain, fs, w - (marker === "none" ? 0 : 0.18));
    const h = (lines * lh) / 72;
    if (lineColor) hairline(slide, x, cy - gap / 2, w, { color: lineColor, pt: 0.5 });
    if (marker === "dot") {
      slide.addShape("rect", { x, y: cy + 0.055, w: 0.052, h: 0.052, fill: { color: markerColor }, line: { type: "none" } });
    } else if (marker === "dash") {
      rect(slide, x, cy + 0.075, 0.14, 0.018, { fill: markerColor, line: null });
    }
    text(slide, item, {
      x: x + (marker === "none" ? 0 : 0.18),
      y: cy,
      w: w - (marker === "none" ? 0 : 0.18),
      h,
      fs,
      lh,
      color,
      page,
    });
    cy += h + gap;
  }
  return cy;
}

export function table(slide, o) {
  const {
    x, y, w, colW,
    data,
    rowH,
    fs = T.table,
    pad = 0.055,
    headerFill = C.panel2,
    zebra = null,
    page = 0,
    label = "table",
  } = o;
  const rows = data.map((row, ri) =>
    row.map((cell) => {
      const isCellObj = cell && typeof cell === "object" && !Array.isArray(cell);
      const value = isCellObj ? cell.text : cell;
      const raw = isCellObj ? cell.options || {} : {};
      const { font, fs: cellFs, fill, ...rest } = raw;
      return {
        text: value,
        options: {
          ...rest,
          fill: { color: fill || (ri === 0 ? headerFill : ri % 2 === 0 && zebra ? zebra : C.panel) },
          color: rest.color || (ri === 0 ? C.ink : C.muted),
          bold: rest.bold ?? ri === 0,
          align: rest.align || "left",
          valign: rest.valign || "middle",
          fontFace: font || F.cjk,
          fontSize: cellFs || fs,
          margin: [pad, pad, pad, pad],
        },
      };
    })
  );
  // Estimate row heights; warn when the fixed height is too small.
  let estimated = 0;
  rows.forEach((row, ri) => {
    let need = 0;
    row.forEach((cell, ci) => {
      const cw = (colW[ci] || 1) - pad * 2 - 0.02;
      const lines = wrapLines(cell.text, cell.options.fontSize, cw, 0);
      need = Math.max(need, (lines * cell.options.fontSize * 1.32) / 72 + pad * 2);
    });
    const given = rowH[ri];
    if (given && need > given + 0.02) {
      warn(`page ${page}: table row ${ri} needs ${need.toFixed(2)}in > ${given.toFixed(2)}in ("${String(row[0].text).slice(0, 14)}")`);
    }
    estimated += Math.max(given || 0, need);
  });
  const bottom = y + estimated;
  if (bottom > H - 0.55) warn(`page ${page}: table "${label}" bottom ${bottom.toFixed(2)}in exceeds safe area`);
  slide.addTable(rows, {
    x, y, w, colW,
    rowH,
    border: { type: "solid", pt: 0.5, color: C.rule },
    fontFace: F.cjk,
    fontSize: fs,
    color: C.muted,
    valign: "middle",
    margin: pad,
    autoPage: false,
  });
}

export function frame(pptx, slide, o) {
  const { no, total, section, claim, source, sub } = o;
  slide.background = { color: C.bg };
  token(slide, String(no).padStart(2, "0"), {
    x: M, y: 0.3, w: 0.42, h: 0.2, fs: 8.6, color: C.accent, page: no,
  });
  text(slide, section, {
    x: M + 0.44, y: 0.295, w: 6.4, h: 0.22, fs: 8.2, color: C.muted, charSpacing: 1.2, page: no,
  });
  token(slide, "SLIPE / STRATEGY 2026", {
    x: W - M - 3.0, y: 0.3, w: 3.0, h: 0.2, fs: 7.4, color: C.dim, align: "right", page: no,
  });
  text(slide, claim, {
    x: M, y: 0.6, w: CW, h: 0.8, fs: T.claim, bold: true, color: C.ink,
    lh: 31, page: no,
  });
  if (sub) {
    text(slide, sub, { x: M, y: 1.24, w: CW, h: 0.24, fs: 9, color: C.muted, page: no });
  }
  hairline(slide, M, sub ? 1.56 : 1.46, CW, { color: C.rule, pt: 0.75 });
  if (source) {
    text(slide, source, { x: M, y: 6.95, w: 10.55, h: 0.24, fs: T.source, color: C.dim, page: no });
  }
  token(slide, `${String(no).padStart(2, "0")} / ${total}`, {
    x: W - M - 1.2, y: 6.99, w: 1.2, h: 0.2, fs: 7.6, color: C.dim, align: "right", page: no,
  });
}

export function notes(slide, lines) {
  slide.addNotes(lines.filter(Boolean).join("\n"));
}

export { addSingleLineToken };
