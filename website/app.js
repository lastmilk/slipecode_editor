/* SLIPE — interactions */

// nav scroll state
const nav = document.getElementById("nav");
const onScroll = () => nav.classList.toggle("scrolled", window.scrollY > 24);
window.addEventListener("scroll", onScroll, { passive: true });
onScroll();

// reveal on scroll
const io = new IntersectionObserver(
  (entries) => {
    for (const e of entries) {
      if (e.isIntersecting) {
        e.target.classList.add("in");
        io.unobserve(e.target);
      }
    }
  },
  { threshold: 0.12 }
);
document.querySelectorAll(".reveal").forEach((el) => io.observe(el));

// cursor glow
const glow = document.getElementById("cursor-glow");
let gx = -600, gy = -600, tx = gx, ty = gy;
window.addEventListener("pointermove", (e) => {
  tx = e.clientX; ty = e.clientY;
  glow.style.opacity = "1";
});
window.addEventListener("pointerleave", () => (glow.style.opacity = "0"));
(function tick() {
  gx += (tx - gx) * 0.12;
  gy += (ty - gy) * 0.12;
  glow.style.left = gx + "px";
  glow.style.top = gy + "px";
  requestAnimationFrame(tick);
})();

// hero phone parallax tilt
const card = document.getElementById("phone-card");
if (card && matchMedia("(pointer: fine)").matches) {
  card.addEventListener("pointermove", (e) => {
    const r = card.getBoundingClientRect();
    const px = (e.clientX - r.left) / r.width - 0.5;
    const py = (e.clientY - r.top) / r.height - 0.5;
    card.style.transform = `rotate(2.5deg) perspective(900px) rotateY(${px * 8}deg) rotateX(${-py * 8}deg)`;
  });
  card.addEventListener("pointerleave", () => {
    card.style.transform = "";
  });
}

// fake terminal build log typing
const LOG = [
  { t: "$ slipe build --release", cls: "cmd" },
  { t: "→ 同步仓库 github.com/you/kaoqing … 完成", cls: "dim" },
  { t: "→ 云端排队 #128 · Flutter 3.35 stable", cls: "" },
  { t: "→ Running `flutter pub get` … 3.2s", cls: "" },
  { t: "→ Compiling Dart → AOT … 41.8s", cls: "" },
  { t: "→ 签名并打包 app-release.apk", cls: "" },
  { t: "✓ 构建成功 · 已推送下载通知到手机", cls: "ok" },
];

const termEl = document.getElementById("terminal-log");
let termStarted = false;

function runTerminal() {
  if (termStarted || !termEl) return;
  termStarted = true;
  let line = 0, ch = 0;
  let out = "";
  const caret = '<span class="caret"></span>';

  function step() {
    if (line >= LOG.length) {
      termEl.innerHTML = out + caret;
      return;
    }
    const { t, cls } = LOG[line];
    const speed = cls === "cmd" ? 34 : 10;
    ch++;
    const slice = t.slice(0, ch);
    const open = cls ? `<span class="${cls}">` : "";
    termEl.innerHTML = out + open + slice + (cls ? "</span>" : "") + caret;
    if (ch >= t.length) {
      out += open + t + (cls ? "</span>" : "") + "\n";
      line++;
      ch = 0;
      setTimeout(step, line === 1 ? 500 : 260);
    } else {
      setTimeout(step, speed);
    }
  }
  step();
}

if (termEl) {
  const tio = new IntersectionObserver(
    (entries) => {
      if (entries[0].isIntersecting) {
        runTerminal();
        tio.disconnect();
      }
    },
    { threshold: 0.4 }
  );
  tio.observe(termEl);
}

// soon cards: prevent dead navigation
document.querySelectorAll('.dl-card[data-soon="true"]').forEach((a) => {
  a.addEventListener("click", (e) => e.preventDefault());
});
