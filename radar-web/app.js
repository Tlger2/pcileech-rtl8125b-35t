/* Never Banned — Rust  |  read-only radar (no memory writes) */
(() => {
  const WORLD = 4000;
  const $ = (id) => document.getElementById(id);
  const mapCv = $("map");
  const overCv = $("overlay");
  const espCv = $("esp");
  const mapCtx = mapCv.getContext("2d");
  const overCtx = overCv.getContext("2d");
  const espCtx = espCv.getContext("2d");

  const COLORS = {
    local: "#3dff6e",
    team: "#2f8f4a",
    enemy: "#e23b3b",
    admin: "#c44cff",
    sleep: "#7a3dff",
    npc: "#f0d23c",
    marked: "#f0a020",
    tc: "#e07cff",
    explosion: "#f08a20",
    gunshot: "#3b8cff",
    ores: "#9b6bff",
    food: "#9b4dff",
    hemp: "#6adf4a",
    berries: "#3d8f3d",
    oreNode: "#f4f4f4",
    container: "#e0a020",
    base: "#e04b4b",
    misc: "#4b8cff",
    animals: "#c44cff",
    vehicle: "#9b4dff",
  };

  const LOOT_CATS = [
    ["ores", "Collectibles Ores", COLORS.ores],
    ["food", "Food", COLORS.food],
    ["hemp", "Hemp", COLORS.hemp],
    ["berries", "Berries", COLORS.berries],
    ["oreNode", "Ores", COLORS.oreNode],
    ["container", "Loot Container", COLORS.container],
    ["base", "Base", COLORS.base],
    ["misc", "Misc", COLORS.misc],
    ["animals", "Animals", COLORS.animals],
    ["vehicle", "Vehicle", COLORS.vehicle],
  ];

  const DROPPED = [
    ["Auto Turret", true], ["Acoustic Guitar", true], ["Advanced Healing Tea", true],
    ["Shovel Bass", false], ["Sunglasses", false], ["Stones", true],
    ["Nailgun Nails", false], ["Wood Armor Helmet", false], ["Potato", false],
    ["Potato Seed", false], ["Skinning Knife", false], ["Bandage", false],
    ["M249", true], ["Sheet Metal Door", false], ["Small Candle Set", false],
    ["Pressure Pad", false], ["Metal Facemask", true], ["Assault Rifle", true],
    ["Medical Syringe", true], ["Wood", false],
  ];

  const vis = {
    players: true, teams: true, items: true, animals: true,
    box: true, bone: true, admin: true, expl: true, tc: true, gear: true,
  };

  const lootOn = Object.fromEntries(LOOT_CATS.map(([k]) => [k, true]));
  const droppedOn = Object.fromEntries(DROPPED.map(([n, d]) => [n, d]));
  const colors = { ...COLORS };

  let follow = true;
  let cam = { x: WORLD * 0.52, y: WORLD * 0.48, z: 1 };
  let selected = null;
  let dmaOn = false;
  let fps = 0, frames = 0, lastFps = performance.now();
  const mapCache = document.createElement("canvas");
  let mapDirty = true;
  let viewW = 0, viewH = 0;

  const hash = (x, y) => {
    let n = (x * 374761393 + y * 668265263) | 0;
    n = (n ^ (n >> 13)) * 1274126177;
    return ((n ^ (n >> 16)) >>> 0) / 4294967296;
  };
  const smooth = (t) => t * t * (3 - 2 * t);
  const vnoise = (x, y) => {
    const x0 = Math.floor(x), y0 = Math.floor(y);
    const fx = smooth(x - x0), fy = smooth(y - y0);
    const a = hash(x0, y0), b = hash(x0 + 1, y0);
    const c = hash(x0, y0 + 1), d = hash(x0 + 1, y0 + 1);
    return a + (b - a) * fx + (c - a) * fy + (a - b - c + d) * fx * fy;
  };
  const fbm = (x, y) => {
    let a = 0, amp = 0.5, f = 1;
    for (let i = 0; i < 5; i++) { a += vnoise(x * f, y * f) * amp; amp *= 0.5; f *= 2; }
    return a;
  };

  const monuments = [
    { name: "Outpost", x: 0.46, y: 0.52 },
    { name: "Bandit Camp", x: 0.38, y: 0.62 },
    { name: "Launch Site", x: 0.62, y: 0.40 },
    { name: "Airfield", x: 0.58, y: 0.58 },
    { name: "Military Tunnels", x: 0.50, y: 0.36 },
    { name: "Harbor", x: 0.32, y: 0.48 },
    { name: "Power Plant", x: 0.70, y: 0.50 },
    { name: "Train Yard", x: 0.54, y: 0.70 },
  ];

  function landMask(nx, ny) {
    const dx = (nx - 0.5) / 0.42;
    const dy = (ny - 0.5) / 0.36;
    const r = dx * dx + dy * dy;
    const n = fbm(nx * 4.2, ny * 4.2);
    return 0.62 - r + (n - 0.5) * 0.55;
  }

  function paintMap() {
    const s = 900;
    mapCache.width = s;
    mapCache.height = s;
    const c = mapCache.getContext("2d");
    const img = c.createImageData(s, s);
    const d = img.data;
    for (let y = 0; y < s; y++) {
      for (let x = 0; x < s; x++) {
        const nx = x / s, ny = y / s;
        const m = landMask(nx, ny);
        const i = (y * s + x) * 4;
        let r, g, b;
        if (m < 0) {
          const deep = Math.max(0, Math.min(1, -m));
          r = 18 + deep * 10; g = 58 + deep * 20; b = 78 + deep * 30;
        } else if (m < 0.045) {
          r = 196; g = 184; b = 140;
        } else {
          const elev = fbm(nx * 6, ny * 6);
          if (ny < 0.28 && elev > 0.45) { r = 214; g = 222; b = 226; }
          else if (ny > 0.72 && nx < 0.45) { r = 176; g = 154; b = 86; }
          else if (elev > 0.58) { r = 58; g = 92; b = 40; }
          else { r = 106; g = 138; b = 62; }
        }
        d[i] = r; d[i + 1] = g; d[i + 2] = b; d[i + 3] = 255;
      }
    }
    c.putImageData(img, 0, 0);
    c.strokeStyle = "rgba(40,70,80,.25)";
    c.lineWidth = 1;
    for (let g = 0; g < 16; g++) {
      const p = (g / 16) * s;
      c.beginPath(); c.moveTo(p, 0); c.lineTo(p, s); c.stroke();
      c.beginPath(); c.moveTo(0, p); c.lineTo(s, p); c.stroke();
    }
    c.font = "11px Segoe UI";
    c.fillStyle = "rgba(20,30,28,.75)";
    monuments.forEach((m) => {
      const px = m.x * s, py = m.y * s;
      c.fillRect(px - 28, py - 8, 56, 14);
      c.fillStyle = "#d8ece8";
      c.textAlign = "center";
      c.fillText(m.name, px, py + 3);
      c.fillStyle = "rgba(20,30,28,.75)";
    });
    mapDirty = false;
  }

  function rand(a, b) { return a + Math.random() * (b - a); }
  function pickLand() {
    for (let i = 0; i < 40; i++) {
      const x = rand(WORLD * 0.2, WORLD * 0.8);
      const y = rand(WORLD * 0.2, WORLD * 0.8);
      if (landMask(x / WORLD, y / WORLD) > 0.05) return { x, y };
    }
    return { x: WORLD * 0.5, y: WORLD * 0.5 };
  }

  const local = {
    id: "local", kind: "player", role: "local", name: "you",
    ...pickLand(), vx: 0, vy: 0, yaw: 0, hp: 92, dist: 0, team: "A",
    steam: "76561198000000000", admin: false, sleeping: false,
    belt: ["Assault Rifle", "Medical Syringe", "Bandage"],
    gear: ["Metal Facemask", "Road Sign Kilt", "Hoodie"],
  };

  const players = [local];
  const names = ["Kranchy", "w1ckd", "Helix", "Nøva", "Brick", "Sable", "Rook", "Ivy"];
  for (let i = 0; i < 7; i++) {
    const p = pickLand();
    const role = i === 0 ? "team" : i === 1 ? "admin" : "enemy";
    players.push({
      id: "p" + i, kind: "player", role, name: names[i],
      x: p.x, y: p.y, vx: rand(-18, 18), vy: rand(-18, 18),
      yaw: rand(0, Math.PI * 2), hp: rand(40, 100) | 0,
      team: role === "team" ? "A" : "B",
      steam: "76561198" + String(10000000 + i).padStart(8, "0"),
      admin: role === "admin", sleeping: i === 6,
      belt: role === "enemy" || role === "admin" ? ["AK47", "Syringe", "C4"] : ["Semi", "Apple"],
      gear: ["Wood Armor Helmet", "Hoodie", "Pants"],
      marked: false,
    });
  }

  const npcs = Array.from({ length: 4 }, (_, i) => {
    const p = pickLand();
    return { id: "n" + i, kind: "npc", role: "npc", name: "Scientist", x: p.x, y: p.y, vx: rand(-8, 8), vy: rand(-8, 8), yaw: 0 };
  });

  const animals = ["Boar", "Wolf", "Bear", "Stag"].map((name, i) => {
    const p = pickLand();
    return { id: "a" + i, kind: "animal", name, cat: "animals", x: p.x, y: p.y, vx: rand(-12, 12), vy: rand(-12, 12) };
  });

  const items = [];
  const itemSpecs = [
    ["Metal Ore", "oreNode"], ["Stone", "ores"], ["Hemp", "hemp"],
    ["Red Berry", "berries"], ["Yellow Berry", "berries"], ["Corn", "food"],
    ["M249", "misc"], ["Elite Crate", "container"], ["Military Crate", "container"],
    ["Tool Cupboard", "base"], ["Sleeping Bag", "base"], ["Minicopter", "vehicle"],
    ["Wood", "misc"], ["Auto Turret", "base"],
  ];
  itemSpecs.forEach(([name, cat], i) => {
    const p = pickLand();
    items.push({ id: "i" + i, kind: "item", name, cat, x: p.x, y: p.y });
  });
  for (let i = 0; i < 18; i++) {
    const p = pickLand();
    const [name, cat] = itemSpecs[i % itemSpecs.length];
    items.push({ id: "j" + i, kind: "item", name, cat, x: p.x, y: p.y });
  }

  const bags = Array.from({ length: 5 }, (_, i) => {
    const p = pickLand();
    return { id: "b" + i, kind: "bag", name: "Sleeping Bag", x: p.x, y: p.y };
  });
  const tcs = Array.from({ length: 3 }, (_, i) => {
    const p = pickLand();
    return { id: "t" + i, kind: "tc", name: "Tool Cupboard", x: p.x, y: p.y, wood: 12000 + i * 800, stone: 8000, metal: 2200, hq: 40 };
  });
  const explosions = [];
  let gunshots = [];

  function tick(dt) {
    const clampLand = (e) => {
      e.x = Math.max(80, Math.min(WORLD - 80, e.x));
      e.y = Math.max(80, Math.min(WORLD - 80, e.y));
      if (landMask(e.x / WORLD, e.y / WORLD) < 0) {
        e.vx *= -1; e.vy *= -1;
        e.x += e.vx * dt; e.y += e.vy * dt;
      }
    };
    players.forEach((p) => {
      if (p.role === "local") {
        p.x += Math.cos(p.yaw) * 22 * dt;
        p.y += Math.sin(p.yaw) * 22 * dt;
        p.yaw += Math.sin(performance.now() / 1800) * 0.35 * dt;
      } else if (!p.sleeping) {
        p.x += p.vx * dt; p.y += p.vy * dt;
        if (Math.random() < 0.01) { p.vx = rand(-22, 22); p.vy = rand(-22, 22); }
      }
      clampLand(p);
      p.dist = Math.hypot(p.x - local.x, p.y - local.y);
    });
    [...npcs, ...animals].forEach((e) => {
      e.x += e.vx * dt; e.y += e.vy * dt;
      if (Math.random() < 0.02) { e.vx = rand(-14, 14); e.vy = rand(-14, 14); }
      clampLand(e);
    });
    if (Math.random() < 0.04) {
      const p = pickLand();
      explosions.push({ x: p.x, y: p.y, t: 1.2 });
    }
    explosions.forEach((e) => { e.t -= dt; });
    for (let i = explosions.length - 1; i >= 0; i--) if (explosions[i].t <= 0) explosions.splice(i, 1);
    if (Math.random() < 0.08) {
      const src = players[1 + (Math.random() * (players.length - 1)) | 0];
      gunshots.push({ x: src.x, y: src.y, t: 0.4 });
    }
    gunshots.forEach((g) => { g.t -= dt; });
    gunshots = gunshots.filter((g) => g.t > 0);
    if (follow) { cam.x = local.x; cam.y = local.y; }
  }

  function worldToScreen(x, y) {
    const scale = Math.min(viewW, viewH) * cam.z / WORLD;
    return {
      sx: viewW / 2 + (x - cam.x) * scale,
      sy: viewH / 2 + (y - cam.y) * scale,
      scale,
    };
  }

  function resize() {
    const wrap = mapCv.parentElement;
    viewW = wrap.clientWidth; viewH = wrap.clientHeight;
    [mapCv, overCv].forEach((c) => { c.width = viewW; c.height = viewH; });
    espCv.width = espCv.clientWidth * devicePixelRatio;
    espCv.height = espCv.clientHeight * devicePixelRatio;
  }

  function drawMap() {
    if (mapDirty) paintMap();
    mapCtx.setTransform(1, 0, 0, 1, 0, 0);
    mapCtx.fillStyle = "#123040";
    mapCtx.fillRect(0, 0, viewW, viewH);
    const scale = Math.min(viewW, viewH) * cam.z / WORLD;
    const dx = viewW / 2 - cam.x * scale;
    const dy = viewH / 2 - cam.y * scale;
    mapCtx.drawImage(mapCache, 0, 0, mapCache.width, mapCache.height, dx, dy, WORLD * scale, WORLD * scale);
  }

  function roleColor(p) {
    if (p.marked) return colors.marked;
    if (p.admin && vis.admin) return colors.admin;
    if (p.sleeping) return colors.sleep;
    if (p.role === "local") return colors.local;
    if (p.role === "team") return colors.team;
    if (p.role === "npc") return colors.npc;
    return colors.enemy;
  }

  function drawDot(ctx, sx, sy, color, size, heading) {
    ctx.fillStyle = color;
    ctx.beginPath();
    ctx.arc(sx, sy, size, 0, Math.PI * 2);
    ctx.fill();
    ctx.strokeStyle = "#111";
    ctx.lineWidth = 1;
    ctx.stroke();
    if (heading != null) {
      ctx.beginPath();
      ctx.moveTo(sx, sy);
      ctx.lineTo(sx + Math.cos(heading) * size * 2.4, sy + Math.sin(heading) * size * 2.4);
      ctx.strokeStyle = color;
      ctx.stroke();
    }
  }

  function drawOverlay() {
    overCtx.clearRect(0, 0, viewW, viewH);
    if (vis.items) {
      items.forEach((it) => {
        if (!lootOn[it.cat]) return;
        if (it.kind === "item" && droppedOn[it.name] === false && DROPPED.some((d) => d[0] === it.name)) return;
        const { sx, sy } = worldToScreen(it.x, it.y);
        if (sx < -20 || sy < -20 || sx > viewW + 20 || sy > viewH + 20) return;
        overCtx.fillStyle = colors[it.cat] || "#fff";
        overCtx.fillRect(sx - 3, sy - 3, 6, 6);
      });
    }
    if (vis.tc) {
      tcs.forEach((t) => {
        const { sx, sy } = worldToScreen(t.x, t.y);
        overCtx.fillStyle = colors.tc;
        overCtx.fillRect(sx - 4, sy - 4, 8, 8);
        overCtx.fillStyle = "#fff";
        overCtx.font = "9px Segoe UI";
        overCtx.fillText("TC", sx + 6, sy);
      });
      bags.forEach((b) => {
        const { sx, sy } = worldToScreen(b.x, b.y);
        overCtx.fillStyle = colors.sleep;
        overCtx.beginPath();
        overCtx.arc(sx, sy, 3, 0, Math.PI * 2);
        overCtx.fill();
      });
    }
    if (vis.expl) {
      explosions.forEach((e) => {
        const { sx, sy } = worldToScreen(e.x, e.y);
        overCtx.strokeStyle = colors.explosion;
        overCtx.globalAlpha = Math.max(0, e.t);
        overCtx.beginPath();
        overCtx.arc(sx, sy, 10 + (1.2 - e.t) * 18, 0, Math.PI * 2);
        overCtx.stroke();
        overCtx.globalAlpha = 1;
      });
      gunshots.forEach((g) => {
        const { sx, sy } = worldToScreen(g.x, g.y);
        overCtx.fillStyle = colors.gunshot;
        overCtx.globalAlpha = g.t / 0.4;
        overCtx.beginPath(); overCtx.arc(sx, sy, 3, 0, Math.PI * 2); overCtx.fill();
        overCtx.globalAlpha = 1;
      });
    }
    if (vis.animals) {
      animals.forEach((a) => {
        if (!lootOn.animals) return;
        const { sx, sy } = worldToScreen(a.x, a.y);
        drawDot(overCtx, sx, sy, colors.animals, 4);
        overCtx.fillStyle = "#dfe";
        overCtx.font = "9px Segoe UI";
        overCtx.fillText(a.name, sx + 6, sy - 4);
      });
    }
    npcs.forEach((n) => {
      const { sx, sy } = worldToScreen(n.x, n.y);
      drawDot(overCtx, sx, sy, colors.npc, 4);
    });
    players.forEach((p) => {
      if (p.role === "team" && !vis.teams) return;
      if (p.role !== "local" && p.role !== "team" && !vis.players) return;
      const { sx, sy } = worldToScreen(p.x, p.y);
      const col = roleColor(p);
      if (vis.box && p.role !== "local") {
        overCtx.strokeStyle = col;
        overCtx.strokeRect(sx - 7, sy - 7, 14, 14);
      }
      drawDot(overCtx, sx, sy, col, p.role === "local" ? 5 : 4, p.yaw);
      overCtx.fillStyle = "#e8f4f1";
      overCtx.font = "10px Segoe UI";
      const tag = p.admin && vis.admin ? p.name + " [admin]" : p.name;
      overCtx.fillText(tag, sx + 8, sy - 6);
      if (p.role !== "local") {
        overCtx.fillStyle = "#9ab";
        overCtx.fillText((p.dist | 0) + "m", sx + 8, sy + 6);
      }
    });
  }

  function drawEsp() {
    const w = espCv.width, h = espCv.height;
    espCtx.setTransform(1, 0, 0, 1, 0, 0);
    espCtx.fillStyle = "#0c1012";
    espCtx.fillRect(0, 0, w, h);
    const near = players.filter((p) => p.role !== "local" && p.dist < 220).sort((a, b) => a.dist - b.dist);
    const cx = w * 0.5, ground = h * 0.78;
    near.forEach((p, i) => {
      const rel = p.yaw - local.yaw;
      const ang = Math.atan2(p.y - local.y, p.x - local.x) - local.yaw;
      const depth = Math.max(0.2, p.dist / 220);
      const x = cx + Math.sin(ang) * (w * 0.38) * (1 - depth * 0.3);
      const scale = (1 - depth) * (h * 0.45) + 18;
      const col = roleColor(p);
      espCtx.strokeStyle = col;
      espCtx.fillStyle = col;
      if (vis.box) {
        espCtx.globalAlpha = 0.9;
        espCtx.strokeRect(x - scale * 0.18, ground - scale, scale * 0.36, scale);
      }
      if (vis.bone) {
        const top = ground - scale;
        const mid = ground - scale * 0.55;
        const hip = ground - scale * 0.38;
        espCtx.beginPath();
        espCtx.arc(x, top + 6, 4, 0, Math.PI * 2);
        espCtx.moveTo(x, top + 10); espCtx.lineTo(x, hip);
        espCtx.moveTo(x - scale * 0.16, mid); espCtx.lineTo(x + scale * 0.16, mid);
        espCtx.moveTo(x, hip); espCtx.lineTo(x - scale * 0.12, ground);
        espCtx.moveTo(x, hip); espCtx.lineTo(x + scale * 0.12, ground);
        espCtx.stroke();
      }
      espCtx.globalAlpha = 1;
      espCtx.font = Math.max(9, 11 * devicePixelRatio) + "px Segoe UI";
      espCtx.fillText(p.name + "  " + (p.dist | 0) + "m", x - scale * 0.18, ground - scale - 4);
    });
    animals.forEach((a) => {
      if (!vis.animals) return;
      const dist = Math.hypot(a.x - local.x, a.y - local.y);
      if (dist > 160) return;
      const ang = Math.atan2(a.y - local.y, a.x - local.x) - local.yaw;
      const x = cx + Math.sin(ang) * (w * 0.3);
      espCtx.fillStyle = colors.animals;
      espCtx.fillRect(x - 4, ground - 10, 8, 10);
    });
  }

  function hud() {
    const enemies = players.filter((p) => p.role === "enemy" || p.role === "admin").length;
    const sleepers = players.filter((p) => p.sleeping).length;
    $("hud-stats").innerHTML = [
      ["Ws", fps.toFixed(0) + " FPS"],
      ["Network", dmaOn ? "DMA live" : "demo 2.1ms"],
      ["Players", enemies + " live"],
      ["Sleeping", sleepers],
      ["Amount", (items.length + animals.length) + " ents"],
      ["Admins", players.filter((p) => p.admin).length],
      ["Map seed", "1337"],
      ["Size", "3650"],
    ].map(([k, v]) => `<div><span class="k">${k}</span><span>${v}</span></div>`).join("");
  }

  function lootUi() {
    const box = $("loot-filter");
    box.innerHTML = `<div class="panel-head">Loot Filter</div><div class="grid"></div>`;
    const grid = box.querySelector(".grid");
    LOOT_CATS.forEach(([k, label, col]) => {
      const lab = document.createElement("label");
      lab.innerHTML = `<span class="swatch" style="background:${colors[k] || col}"></span>${label}`;
      const inp = document.createElement("input");
      inp.type = "checkbox"; inp.checked = lootOn[k];
      inp.addEventListener("change", () => { lootOn[k] = inp.checked; });
      lab.appendChild(inp);
      grid.appendChild(lab);
    });
  }

  function showCard(p) {
    selected = p;
    const el = $("player-card");
    el.classList.remove("hidden");
    const gear = vis.gear ? `<div class="gear"><b>Belt / gear</b><div>${[...p.belt, ...p.gear].map((g) => `<span class="chip">${g}</span>`).join("")}</div></div>` : "";
    el.innerHTML = `
      <div class="who">
        <h2>${p.name} ${p.admin ? "· admin" : ""}</h2>
        <div>Steam · ${p.steam}</div>
        <div><a href="https://steamcommunity.com/profiles/${p.steam}" target="_blank" rel="noreferrer">Steam Profile</a></div>
        <div class="btn-row" style="margin-top:8px">
          <button type="button" class="btn" id="mark-p">Mark player</button>
          <button type="button" class="btn" id="close-p">Close</button>
        </div>
      </div>
      <div class="inv">
        <div>Sleeping ${p.sleeping ? "yes" : "no"}</div>
        <div>Team ${p.team}</div>
        <div>HP ${p.hp | 0}</div>
        <div>${(p.dist | 0)}m</div>
      </div>${gear}`;
    $("mark-p").onclick = () => { p.marked = !p.marked; showCard(p); };
    $("close-p").onclick = () => { el.classList.add("hidden"); selected = null; };
  }

  function hitTest(mx, my) {
    let best = null, bestD = 14;
    players.forEach((p) => {
      const { sx, sy } = worldToScreen(p.x, p.y);
      const d = Math.hypot(sx - mx, sy - my);
      if (d < bestD) { best = p; bestD = d; }
    });
    return best;
  }

  function settingsBody(tab) {
    const body = $("settings-body");
    if (tab === "colors") {
      const groups = [
        ["Player", [["local", "Local player"], ["team", "Teammate"], ["enemy", "Enemy Player"], ["admin", "Admin"], ["sleep", "Sleeping Player"], ["npc", "NPC"], ["marked", "Marked player"]]],
        ["Entity", [["tc", "Marked TC / Sleeping Bag"], ["explosion", "Explosions"], ["gunshot", "Gunshots"], ["ores", "Collectibles Ores"], ["food", "Food"], ["hemp", "Hemp"], ["berries", "Berries"], ["oreNode", "Ores"], ["container", "Loot Container"], ["base", "Base"], ["misc", "Misc"], ["animals", "Animals"], ["vehicle", "Vehicle"]]],
      ];
      body.innerHTML = groups.map(([title, rows]) =>
        `<h3 style="color:var(--teal)">${title}</h3>` +
        rows.map(([k, n]) =>
          `<label class="color-row">${n}<input type="color" data-col="${k}" value="${toHex(colors[k])}"><span class="dot" style="background:${colors[k]}"></span></label>`
        ).join("")
      ).join("");
      body.querySelectorAll("input[type=color]").forEach((inp) => {
        inp.addEventListener("input", () => { colors[inp.dataset.col] = inp.value; lootUi(); });
      });
      return;
    }
    if (tab === "dropped") {
      body.innerHTML = DROPPED.map(([n]) =>
        `<label class="drop-row">${n}<input type="checkbox" data-drop="${n}" ${droppedOn[n] ? "checked" : ""}></label>`
      ).join("");
      body.querySelectorAll("input").forEach((inp) => {
        inp.addEventListener("change", () => { droppedOn[inp.dataset.drop] = inp.checked; });
      });
      return;
    }
    if (tab === "hotkeys") {
      body.innerHTML = `<p class="hint">F2 player overlay · F3 settings · scroll zoom · drag pan · click player for info. No write binds.</p>`;
      return;
    }
    if (tab === "misc") {
      body.innerHTML = `<p class="hint">Read-only radar. Aimbot, RCS, chams, spiderman, bright night/caves, instant eoka, and camera writes are not in this build.</p>`;
      return;
    }
    body.innerHTML = `<p class="hint">General: follow local on the map, DMA connect is a status hook (no writes). Visuals live in the right menu.</p>`;
  }

  function toHex(c) {
    if (c.startsWith("#") && c.length === 7) return c;
    return "#2fa38a";
  }

  function exportFortify() {
    const payload = {
      note: "read-only base snapshot",
      tcs: tcs.map((t) => ({ x: t.x | 0, y: t.y | 0, wood: t.wood, stone: t.stone, metal: t.metal, hq: t.hq })),
      bags: bags.map((b) => ({ x: b.x | 0, y: b.y | 0 })),
    };
    const blob = new Blob([JSON.stringify(payload, null, 2)], { type: "application/json" });
    const a = document.createElement("a");
    a.href = URL.createObjectURL(blob);
    a.download = "never-banned-fortify.json";
    a.click();
    URL.revokeObjectURL(a.href);
  }

  overCv.classList.add("interactive");
  overCv.addEventListener("click", (e) => {
    const r = overCv.getBoundingClientRect();
    const hit = hitTest(e.clientX - r.left, e.clientY - r.top);
    if (hit) showCard(hit);
    else $("player-card").classList.add("hidden");
  });
  overCv.addEventListener("wheel", (e) => {
    e.preventDefault();
    cam.z = Math.max(0.6, Math.min(3.2, cam.z * (e.deltaY > 0 ? 0.92 : 1.08)));
  }, { passive: false });

  let drag = null;
  overCv.addEventListener("mousedown", (e) => { drag = { x: e.clientX, y: e.clientY, cx: cam.x, cy: cam.y }; follow = false; $("btn-follow").classList.remove("on"); });
  window.addEventListener("mouseup", () => { drag = null; });
  window.addEventListener("mousemove", (e) => {
    if (!drag) return;
    const scale = Math.min(viewW, viewH) * cam.z / WORLD;
    cam.x = drag.cx - (e.clientX - drag.x) / scale;
    cam.y = drag.cy - (e.clientY - drag.y) / scale;
  });

  $("btn-follow").onclick = () => { follow = !follow; $("btn-follow").classList.toggle("on", follow); };
  $("btn-reload-map").onclick = () => { mapDirty = true; };
  $("btn-reload-radar").onclick = () => { mapDirty = true; };
  $("btn-dma").onclick = () => {
    dmaOn = !dmaOn;
    $("btn-dma").textContent = dmaOn ? "Disconnect" : "Connect DMA";
    $("dma-status").textContent = dmaOn
      ? "Connected · FT601 read path (no writes)"
      : "Disconnected · demo world";
  };
  $("btn-fortify").onclick = exportFortify;

  document.querySelectorAll("[data-tab]").forEach((b) => {
    b.onclick = () => {
      document.querySelectorAll("[data-tab]").forEach((x) => x.classList.remove("active"));
      b.classList.add("active");
      if (b.dataset.tab !== "radar") {
        $("settings-modal").classList.remove("hidden");
        document.querySelectorAll("[data-settab]").forEach((t) => t.classList.toggle("on", t.dataset.settab === (b.dataset.tab === "loot" ? "dropped" : b.dataset.tab === "hotkeys" ? "hotkeys" : "colors")));
        settingsBody(b.dataset.tab === "loot" ? "dropped" : b.dataset.tab === "settings" ? "colors" : b.dataset.tab);
      }
    };
  });
  $("settings-close").onclick = () => $("settings-modal").classList.add("hidden");
  document.querySelectorAll("[data-settab]").forEach((t) => {
    t.onclick = () => {
      document.querySelectorAll("[data-settab]").forEach((x) => x.classList.remove("on"));
      t.classList.add("on");
      settingsBody(t.dataset.settab);
    };
  });

  [
    ["vis-players", "players"], ["vis-teams", "teams"], ["vis-items", "items"],
    ["vis-animals", "animals"], ["vis-box", "box"], ["vis-bone", "bone"],
    ["vis-admin", "admin"], ["vis-expl", "expl"], ["vis-tc", "tc"], ["vis-gear", "gear"],
  ].forEach(([id, k]) => {
    $(id).addEventListener("change", (e) => { vis[k] = e.target.checked; });
  });

  window.addEventListener("keydown", (e) => {
    if (e.key === "F3") $("settings-modal").classList.toggle("hidden");
    if (e.key === "F2" && selected) $("player-card").classList.toggle("hidden");
  });
  window.addEventListener("resize", resize);

  lootUi();
  resize();
  paintMap();

  let last = performance.now();
  function frame(now) {
    const dt = Math.min(0.05, (now - last) / 1000);
    last = now;
    tick(dt);
    drawMap();
    drawOverlay();
    drawEsp();
    frames++;
    if (now - lastFps > 500) {
      fps = frames * 1000 / (now - lastFps);
      frames = 0; lastFps = now;
      hud();
    }
    requestAnimationFrame(frame);
  }
  hud();
  requestAnimationFrame(frame);
})();
