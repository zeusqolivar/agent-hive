/* Classroom view: draws live sessions as characters in an isometric classroom. Where a character stands comes from
   real session state. The room is a tile grid (room-model.js): the saved arrangement, or the automatic one when
   nothing is saved. Positions stay in flat room units (TILE per tile); only the drawing is isometric. */
"use strict";
const Room = (() => {
  const BODY = ["#4C6FD6","#C9562F","#17948A","#8A5CD1","#D0457F","#5B9A38","#2E8BC7","#5A6680"];
  const LABEL = {read:"Reading", write:"Writing", run:"Running a command", web:"On the web", think:"Thinking", tool:"Using a tool", subagents:"With helpers"};
  const ASK = {question:"Question", permission:"Needs OK", plan:"Approve plan", other:"Waiting"};
  const NAP_AFTER = 6 * 3600;
  const T = RoomModel.TILE, CAT = RoomModel.CATALOGUE, WR = RoomModel.WALL_ROWS;
  // Projection: a floor tile is a 64 by 32 diamond, a wall row is 44 units tall. The back wall stands along the
  // first floor row (the wall rows of the grid are its height), the left wall along column 0.
  const HW = 32, HH = 16, WZ = 44, WALLH = WR * WZ, TOP = 34, PADX = 22, PADB = 30, SLAB = 12, THICK = .3;
  // How tall each standing item is drawn, for depth sorting and for picking it in the editor.
  // The straight view: a front-facing three-quarter room. A tile is SX wide and SY deep (foreshortened), heights
  // are drawn as they are, and the side walls are SIDE tiles thick.
  const SX = HW, SY = HW*.78, SIDE = .45, S_PADX = 12, S_PADB = 16;
  // Characters' scale: sessions and their subagents, a little smaller in the straight view where they're nearer.
  let BIG = 1.08, SUB = .66;
  const TALL = {desk:62, shelf:48, plant:54, globe:74, machine:82, beanbag:28, couch:38, fountain:70, lamp:98, rug:0};
  const hash = s => { let h = 7; for(const c of String(s)) h = (h * 31 + c.charCodeAt(0)) >>> 0; return h; };
  const hash2 = (a, b) => { let h = Math.imul(a | 0, 374761393) ^ Math.imul(b | 0, 668265263); h = Math.imul(h ^ h >>> 13, 1274126177); return (h ^ h >>> 16) >>> 0; };
  let placed = [], keepOut = [], heads = [], hitList = [], editHits = null, cv, ctx, agents = new Map(), board = null, active = false, last = 0;
  let sel = null, hover = null, pointerOn = null, onPick = () => {}, k = 1, ox = 0, oy = 0;
  const calm = matchMedia("(prefers-reduced-motion:reduce)");
  // saved: the room from /api/classroom, or null for the automatic one. G: everything derived from the room in use.
  let deskState = {deskCount:0, layoutAt:0, assign:{}}, saved = null, problem = null, G = null, W = 0, H = 0;
  // The drawing's size and origin: X0, Y0 is where the floor's back corner (tile 0, WALL_ROWS) is drawn.
  let SW = 0, SH = 0, X0 = 0, Y0 = 0;
  // The camera: rot is the view (0 to 3, a quarter turn each), RC and RF the floor's size in tiles. cam holds what
  // the viewer chose: the turn, the zoom relative to fitting the canvas, and the floor point (tiles) at the centre,
  // or null for the fitted centre. kFit is the scale that fits the drawing in the canvas, CW and CH the canvas size.
  let rot = 0, RC = 0, RF = 0, kFit = 1, CW = 0, CH = 0, straight = true;
  // view: "straight" (front-facing, the default) or "angled" (isometric, in four turns).
  const cam = {view:"straight", rot:0, zoom:1, cx:null, cy:null};
  const ZOOM_MIN = .6, ZOOM_MAX = 3;
  // Edit mode (room-editor.js): the draft being edited, and what to show on it ({selected, ghost}).
  let draft = null, view = {};
  let palette = {}, themeGen = 0;
  // Kept in a variable: an unreferenced MediaQueryList can be collected, and its listener with it.
  const darkQuery = matchMedia("(prefers-color-scheme:dark)");
  darkQuery.addEventListener("change", () => { palette = {}; themeGen++; });
  const css = n => palette[n] ??= getComputedStyle(document.documentElement).getPropertyValue(n).trim();
  const hexv = (n, d) => { const v = css(n); return /^#[0-9a-f]{6}$/i.test(v) ? v : d; };
  const centre = p => ({x:(p.x + .5)*T, y:(p.y + .5)*T});
  const tileOf = p => ({x:Math.floor(p.x / T), y:Math.floor(p.y / T)});
  // A desk's chair, in room units: in the front half of the desk's footprint, so its sitter faces the board.
  const chairPt = d => ({x:(d.x + 1.5)*T, y:(d.y + 1.45)*T});

  // How many desks a saved room needs: one per assigned session.
  const needed = () => Object.values(deskState.assign).reduce((m, i) => Math.max(m, i + 1), 0);
  function build(){
    const room = saved || RoomModel.autoRoom(deskState.deskCount);
    const grid = RoomModel.walkGrid(room), spots = RoomModel.spots(room), want = saved ? needed() : deskState.deskCount;
    const slots = RoomModel.deskSlots(room, want);
    const front = room.rows - RoomModel.FRONT_ROWS;
    // Tiles for sessions that get no desk because the floor is full: open floor, away from the activity spots.
    const busy = new Set(Object.values(spots).flat().map(p => p.x + "," + p.y));
    const stand = [];
    for(let y = RoomModel.WALL_ROWS; y < front; y++) for(let x = 0; x < room.cols; x++) if(grid.ok(x, y) && !busy.has(x + "," + y)) stand.push({x, y});
    const mid = {x:room.cols/2, y:(RoomModel.WALL_ROWS + front)/2};
    stand.sort((p, q) => Math.hypot(p.x - mid.x, p.y - mid.y) - Math.hypot(q.x - mid.x, q.y - mid.y));
    const dt = RoomModel.doorTile(room) || {x:room.cols - 3, y:RoomModel.WALL_ROWS};
    G = {room, grid, spots, slots, want, stand, door:centre(dt), ...frontOf(room)};
    dims();
  }
  // The fixed front of the room: the "needs you" mat, the queue on it, and your desk.
  const frontOf = room => ({queueY:room.rows*T - 84, matTop:room.rows*T - 160, matBottom:room.rows*T - 55, yourDeskY:room.rows*T - 48});
  // The drawing's size follows the draft while editing, otherwise the room in use.
  function dims(){
    const r = draft || G.room, F = r.rows - WR;
    W = r.cols*T; H = r.rows*T; RC = r.cols; RF = F; rot = cam.rot; straight = cam.view !== "angled";
    BIG = straight ? .92 : 1.08; SUB = straight ? .58 : .66;
    if(straight){
      X0 = S_PADX + SIDE*SX; Y0 = TOP + WALLH + THICK*SY;
      SW = r.cols*SX + 2*X0; SH = Y0 + F*SY + SLAB + S_PADB;
      return;
    }
    // A quarter turn swaps the floor's sides, so the far corner moves; the drawing's size stays the same.
    X0 = PADX + (rot % 2 ? r.cols : F)*HW; Y0 = TOP + WALLH;
    SW = (r.cols + F)*HW + 2*PADX; SH = (r.cols + F)*HH + TOP + WALLH + PADB;
  }
  // A new room or desk count moves desks and spots, so everyone picks a destination again and walks there.
  function relayout(){
    build();
    for(const a of agents.values()){
      a.x = Math.max(20, Math.min(W - 20, a.x)); a.y = Math.max(RoomModel.WALL_ROWS*T + 10, Math.min(H - 20, a.y));
      a.path = []; a.nextMove = 0; a.retry = 0;
      if(!a.leaving) a.dest = null;
    }
    if(cv) size();
  }

  // Walks over free tiles. A character on a blocked tile (at its desk, or furniture moved under it) first steps to the nearest free one.
  function route(a, to){
    const g = G.grid, pts = [];
    let from = tileOf(a);
    if(!g.ok(from.x, from.y)){
      const out = RoomPath.nearestOpen(g, from);
      if(!out) return [{x:to.x, y:to.y}];
      pts.push(centre(out)); from = out;
    }
    let goal = tileOf(to);
    if(!g.ok(goal.x, goal.y)) goal = RoomPath.nearestOpen(g, goal) || goal;
    const steps = RoomPath.findPath(g, from, goal);
    if(steps) for(const s of steps) pts.push(centre(s));
    const end = pts[pts.length - 1];
    if(!end || Math.hypot(end.x - to.x, end.y - to.y) > .5) pts.push({x:to.x, y:to.y});
    return pts;
  }
  function go(a, dest){
    a.dest = dest;
    if(calm.matches){ a.x = dest.x; a.y = dest.y; a.path = []; return; }
    a.path = route(a, dest);
  }
  // Activity spots hold one character each.
  function freeSlot(kind, a){
    const list = G.spots[kind] || [];
    const taken = new Set([...agents.values()].filter(o => o !== a && o.dest?.kind === kind).map(o => o.dest.i));
    const open = list.map((_,i) => i).filter(i => !taken.has(i));
    if(!open.length) return null;
    const i = open[Math.floor(Math.random()*open.length)], p = centre(list[i]);
    return {kind, i, x:p.x, y:p.y};
  }
  // Subagents are small enough to share a spot.
  function anySlot(kind){
    const list = G.spots[kind] || [];
    if(!list.length) return null;
    const p = centre(list[Math.floor(Math.random()*list.length)]);
    return {kind, i:-1, x:p.x + (Math.random() - .5)*18, y:p.y + (Math.random() - .5)*12};
  }
  const HELPER_SPOTS = [-52, 52, -26, 26, -78, 78];
  // A session's desk index; a subagent uses its parent's.
  const deskOf = a => deskState.assign[a.s.isSub ? a.s.parent : a.s.id];
  function seatOf(a){
    const i = deskOf(a);
    if(i === undefined) return {kind:"door", i:-1, ...G.door};
    const slot = G.slots[i];
    if(!slot){
      // No floor left for a desk: stand on a free tile instead of on furniture.
      const p = G.stand.length ? centre(G.stand[(i - G.slots.length) % G.stand.length]) : G.door;
      return {kind:a.s.isSub ? "helper" : "desk", i, x:p.x + (a.s.isSub ? HELPER_SPOTS[a.slot % 6]/3 : 0), y:p.y, standing:true};
    }
    // Subagents sit on stools across the desk, on the row behind it.
    if(a.s.isSub) return {kind:"helper", i:-1, x:(slot.x + 1.5)*T + HELPER_SPOTS[a.slot % 6], y:slot.y*T - 16};
    return {kind:"desk", i, ...chairPt(slot)};
  }
  function plan(a, now, queue){
    const s = a.s;
    if(a.leaving){
      if(a.dest?.kind !== "door"){
        const parent = a.s.parent && agents.get(a.s.parent);
        go(a, parent && !parent.leaving ? {kind:"door", x:parent.x, y:parent.y} : {kind:"door", ...G.door});
      }
      return;
    }
    if(s.group === "needs"){
      const i = queue.indexOf(s.id), n = queue.length;
      let x, y = G.queueY;
      if(straight) ({x, y} = queueSpot(i, n));
      else { const step = Math.min(150, (W - 300) / Math.max(1, n - 1)); x = W/2 + (i - (n-1)/2) * step; }   // wide enough for name tags side by side
      if(a.dest?.kind !== "queue" || a.dest.x !== x || a.dest.y !== y) go(a, {kind:"queue", x, y});
      return;
    }
    if(s.group === "working"){
      const kind = {read:"read", run:"run", web:"web"}[s.doing];
      if(kind && !s.quiet && G.spots[kind].length){
        if(a.dest?.kind !== kind && now >= a.retry){
          a.retry = now + 5;    // a full spot sends it home, so don't turn it around every frame
          go(a, (s.isSub ? anySlot(kind) : freeSlot(kind, a)) || seatOf(a));
        }
      } else {
        // No item offers this activity (or it's desk work): it happens at the desk.
        const home = seatOf(a);
        if(a.dest?.kind !== home.kind || a.dest.x !== home.x || a.dest.y !== home.y) go(a, home);
      }
      return;
    }
    const idleFor = Date.now()/1000 - (s.lastTs || 0);
    if(idleFor > NAP_AFTER){
      if(a.dest?.kind !== "nap" && a.dest?.kind !== "desk"){ go(a, freeSlot("nap", a) || seatOf(a)); }
      a.napping = true;
      return;
    }
    a.napping = false;
    if(a.path.length || now < a.nextMove) return;
    a.nextMove = now + 6 + Math.random()*14;
    if(calm.matches){ if(a.dest?.kind !== "desk") go(a, seatOf(a)); return; }
    const kinds = ["stroll","stroll","stroll","stroll","read","desk"], pick = kinds[Math.floor(Math.random()*kinds.length)];
    go(a, pick === "desk" ? seatOf(a) : freeSlot(pick, a) || seatOf(a));
  }
  // Straight on, the queue stands on the needs-you mat beside your desk (which would hide anyone behind it):
  // first on the left, then the right, then further out, spaced so neighbours and their callouts don't overlap.
  function queueSpot(i, n){
    const half = 220, gap = 70, edge = 150, side = i % 2 ? 1 : -1, k = Math.floor(i/2), each = Math.ceil(n/2);
    const room = W/2 - half - gap - edge, step = Math.min(160, each > 1 ? room/(each - 1) : 160);
    return {x:W/2 + side*(half + gap + k*step), y:G.matTop + 40};   // the back half, so the mat's lettering shows in front
  }
  function update(b){
    board = b;
    if(!G) build();
    const live = (b.sessions || []).filter(s => s.live && s.group !== "ended");
    const helpers = [];
    for(const s of live) for(const h of (s.helpers || []).slice(0, 6)){
      helpers.push({id:"sub:" + h.id, isSub:true, parent:s.id, name:h.description, project:s.project, group:"working", doing:h.doing,
        headline:`Subagent of ${s.name}${h.task ? ": " + h.task : ""}`, subagents:{}, lastTs:s.lastTs});
    }
    const ids = new Set(live.map(s => s.id).concat(helpers.map(h => h.id)));
    // Three misses in a row before someone leaves, so one bad refresh can't empty the room.
    for(const a of agents.values()){ if(ids.has(a.s.id)) a.missed = 0; else if(++a.missed >= 3) a.leaving = true; }
    for(const s of live){ const have = agents.get(s.id); if(have){ have.s = s; have.leaving = false; } }
    // Everyone still in the room keeps a desk, including a session missing from one refresh.
    const inRoom = new Map(live.map(s => [s.id, s]));
    for(const a of agents.values()) if(!a.s.isSub && !a.leaving && !inRoom.has(a.s.id)) inRoom.set(a.s.id, a.s);
    const order = [...inRoom.values()].sort((x,y) => (x.startedAt||0) - (y.startedAt||0) || (x.id < y.id ? -1 : 1)).map(s => s.id);
    const before = deskState.deskCount;
    deskState = ClassroomLayout.assignDesks(deskState, order, Date.now()/1000);
    if(deskState.deskCount !== before) relayout();
    else if(saved && needed() !== G.want) build();    // an arrival in a saved room may need an extra desk
    const first = agents.size === 0;
    const make = (s, x, y, extra) => {
      const h = hash(s.id);
      agents.set(s.id, {s, seed:h % 1000, color:BODY[hash(s.project) % BODY.length], hat:s.isSub ? 0 : h % 4, path:[], mx:0, my:0, dest:null,
        nextMove:0, missed:0, retry:0, x, y, ...extra});
    };
    for(const s of live){
      if(agents.has(s.id)) continue;
      const seat = first ? seatOf({s}) : null;
      make(s, first ? seat.x : G.door.x, first ? seat.y : G.door.y, first ? {dest:seat} : undefined);
    }
    for(const s of helpers){
      const have = agents.get(s.id);
      if(have){ have.s = s; have.leaving = false; continue; }
      const parent = agents.get(s.parent);
      if(!parent) continue;
      // The lowest stool beside the parent's desk that no other running subagent has.
      const taken = new Set([...agents.values()].filter(a => a.s.parent === s.parent && !a.leaving).map(a => a.slot % 6));
      let slot = 0; while(taken.has(slot) && slot < 6) slot++;
      make(s, parent.x, parent.y, {slot});
    }
  }
  // The saved room, or null for the automatic one. A saved room that breaks the rules is ignored, and problem() says why.
  function setRoom(room){
    problem = null;
    if(room){
      const v = RoomModel.validate(room);
      if(!v.ok){ problem = v.errors[0]; room = null; }
    }
    saved = room ? JSON.parse(JSON.stringify(room)) : null;
    relayout();
  }

  // ---------------------------------------------------------------- drawing helpers

  // Colours: mixing toward white or black for lit and shaded faces. Inputs are #rrggbb.
  const RGB = new Map(), MIX = new Map();
  function rgbOf(hex){ let v = RGB.get(hex); if(!v){ const n = parseInt(hex.slice(1, 7), 16); v = [n >> 16 & 255, n >> 8 & 255, n & 255]; RGB.set(hex, v); } return v; }
  function mix(a, b, t){
    const key = a + b + t;
    let v = MIX.get(key);
    if(!v){
      const p = rgbOf(a), q = rgbOf(b);
      v = "#" + p.map((c, i) => Math.max(0, Math.min(255, Math.round(c + (q[i] - c)*t))).toString(16).padStart(2, "0")).join("");
      if(MIX.size > 6000) MIX.clear();
      MIX.set(key, v);
    }
    return v;
  }
  const lit = (c, t) => mix(c, "#ffffff", t), dim = (c, t) => mix(c, "#000000", t);
  const alpha = (hex, a) => { const [r, g, b] = rgbOf(hex); return `rgba(${r},${g},${b},${a})`; };

  // The view is one of four rotations, 90 degrees apart. Floor tiles (u, v) = (x, y - WALL_ROWS) turn into (a, b),
  // and the camera always looks from the +a +b corner: the walls at a = 0 and b = 0 are the far ones.
  function turn(u, v){
    const C = RC, F = RF;
    return rot === 0 ? [u, v] : rot === 1 ? [F - v, u] : rot === 2 ? [C - u, F - v] : [v, C - u];
  }
  function unturn(a, b){
    const C = RC, F = RF;
    return rot === 0 ? [a, b] : rot === 1 ? [b, F - a] : rot === 2 ? [C - a, F - b] : [C - b, a];
  }
  // A direction in the room (tiles) as a direction in the turned frame.
  const turnDir = (dx, dy) => rot === 0 ? [dx, dy] : rot === 1 ? [-dy, dx] : rot === 2 ? [-dx, -dy] : [dy, -dx];
  // Turned-frame (a, b) and height z to drawing units.
  const Q = (a, b, z) => ({x:X0 + (a - b)*HW, y:Y0 + (a + b)*HH - (z || 0)});
  // Tiles (x, y) and height z to drawing units; R() takes room units.
  const P = (tx, ty, z) => {
    if(straight) return {x:X0 + tx*SX, y:Y0 + (ty - WR)*SY - (z || 0)};
    const [a, b] = turn(tx, ty - WR); return Q(a, b, z);
  };
  const R = (x, y, z) => P(x/T, y/T, z);
  // The floor point (tiles) drawn at a drawing-unit point.
  function floorAt(sx, sy){
    if(straight) return {x:(sx - X0)/SX, y:(sy - Y0)/SY + WR};
    const p = (sx - X0)/HW, q = (sy - Y0)/HH, [u, v] = unturn((p + q)/2, (q - p)/2);
    return {x:u, y:v + WR};
  }
  // A floor box in tiles as a box in the turned frame.
  function turnBox(x0, y0, x1, y1){
    const [a0, b0] = turn(x0, y0 - WR), [a1, b1] = turn(x1, y1 - WR);
    return {a0:Math.min(a0, a1), a1:Math.max(a0, a1), b0:Math.min(b0, b1), b1:Math.max(b0, b1)};
  }
  function trace(pts){ ctx.beginPath(); ctx.moveTo(pts[0].x, pts[0].y); for(let i = 1; i < pts.length; i++) ctx.lineTo(pts[i].x, pts[i].y); ctx.closePath(); }
  function poly(pts, fill, stroke, lw){
    trace(pts);
    if(fill){ ctx.fillStyle = fill; ctx.fill(); }
    if(stroke){ ctx.strokeStyle = stroke; ctx.lineWidth = lw || 1; ctx.stroke(); }
  }
  // The outline of a box standing on the floor, x0..x1 by y0..y1 tiles and h units high.
  const hull = (x0, y0, x1, y1, h) => { if(straight) return [P(x0, y0, h), P(x1, y0, h), P(x1, y1, 0), P(x0, y1, 0)]; const r = turnBox(x0, y0, x1, y1); return [Q(r.a0, r.b0, h), Q(r.a1, r.b0, h), Q(r.a1, r.b0, 0), Q(r.a1, r.b1, 0), Q(r.a0, r.b1, 0), Q(r.a0, r.b1, h)]; };
  // A box: lit top, the face toward the front left in the base colour, the face toward the front right in shade.
  function prism(x0, y0, x1, y1, z0, z1, base, o){
    o = o || {};
    if(straight){
      // Straight on: the top and the front.
      const a = P(x0, y0, z1), b = P(x1, y0, z1), c = P(x1, y1, z1), d = P(x0, y1, z1), f = P(x1, y1, z0), g = P(x0, y1, z0);
      poly([g, f, c, d], o.left || base);
      poly([a, b, c, d], o.top || lit(base, .14));
      if(o.line === false) return;
      ctx.lineJoin = "round";
      poly([a, b, f, g], null, o.line || dim(base, .5), .9);
      ctx.beginPath(); ctx.moveTo(d.x, d.y); ctx.lineTo(c.x, c.y); ctx.strokeStyle = lit(base, .28); ctx.lineWidth = .7; ctx.stroke();
      return;
    }
    const r = turnBox(x0, y0, x1, y1);
    const a = Q(r.a0, r.b0, z1), b = Q(r.a1, r.b0, z1), c = Q(r.a1, r.b1, z1), d = Q(r.a0, r.b1, z1), e = Q(r.a1, r.b0, z0), f = Q(r.a1, r.b1, z0), g = Q(r.a0, r.b1, z0);
    poly([e, f, c, b], o.right || dim(base, .22));
    poly([g, f, c, d], o.left || base);
    poly([a, b, c, d], o.top || lit(base, .14));
    if(o.line === false) return;
    ctx.lineJoin = "round";
    poly([a, b, e, f, g, d], null, o.line || dim(base, .5), .9);
    ctx.beginPath(); ctx.moveTo(d.x, d.y); ctx.lineTo(c.x, c.y); ctx.lineTo(b.x, b.y); ctx.strokeStyle = lit(base, .28); ctx.lineWidth = .7; ctx.stroke();
  }
  // Draws parts of one thing back to front for this view: each is [x, y, draw], with its middle in tiles.
  const depth = (x, y) => { if(straight) return y + x*1e-3; const [a, b] = turn(x, y - WR); return a + b; };
  function inOrder(parts){ parts.sort((p, q) => depth(p[0], p[1]) - depth(q[0], q[1])).forEach(p => p[2]()); }
  function plane(m, fn){ ctx.save(); ctx.transform(m[0], m[1], m[2], m[3], m[4], m[5]); fn(); ctx.restore(); }
  // Drawing on an upright face of a box or a wall. n is the face's outward direction ("x+", "x-", "y+", "y-") and
  // at its x or y in tiles. Inside fn, x runs along the face, left to right as seen from outside it (tiles times HW:
  // x on a y+ face, -y on an x+ face, y on an x- face, -x on a y- face), and y is minus the height. A face turned
  // away from the viewer isn't drawn; the result says whether it was.
  const NORMAL = {"x+":[1, 0], "x-":[-1, 0], "y+":[0, 1], "y-":[0, -1]};
  function facing(n){ if(straight) return n === "y+" ? "f" : null; const [da, db] = turnDir(...NORMAL[n]); return da > 0 ? "a" : db > 0 ? "b" : null; }
  function face(n, at, fn){
    const side = facing(n);
    if(!side) return false;
    const o = n[0] === "x" ? P(at, 0, 0) : P(0, at, 0);
    plane([1, side === "f" ? 0 : side === "b" ? .5 : -.5, 0, 1, o.x, o.y], fn);
    return true;
  }
  const faceY = (ty, fn) => face("y+", ty, fn);
  // A box's extent along one of its faces, in face() terms.
  const span = (n, x0, y0, x1, y1) => n === "y+" ? [x0, x1] : n === "y-" ? [-x1, -x0] : n === "x+" ? [-y1, -y0] : [y0, y1];
  const faceX = (tx, fn) => face("x+", tx, fn);
  // On the floor, in flat room units.
  function onFloor(fn){
    const o = P(0, 0), ex = P(1, 0), ey = P(0, 1);
    plane([(ex.x - o.x)/T, (ex.y - o.y)/T, (ey.x - o.x)/T, (ey.y - o.y)/T, o.x, o.y], fn);
  }
  // On the floor in the turned frame, a and b in room units, (0, 0) at the far corner.
  const onFloorTurned = fn => plane([HW/T, HH/T, -HW/T, HH/T, X0, Y0], fn);
  const backShown = () => !!facing("y+");
  const onWall = fn => faceY(WR, fn);
  const wy = y => (y - WR)*WZ;   // a wall row's top edge, on the back wall's face
  function hex(x, y, r){ ctx.beginPath(); for(let i = 0; i < 6; i++){ const t = Math.PI/3*i - Math.PI/2; ctx.lineTo(x + r*Math.cos(t), y + r*Math.sin(t)); } ctx.closePath(); }
  function box(x, y, w, h, r, fill){ ctx.fillStyle = fill; ctx.beginPath(); ctx.roundRect(x, y, w, h, r); ctx.fill(); }
  function oval(x, y, rx, ry, fill){ ctx.fillStyle = fill; ctx.beginPath(); ctx.ellipse(x, y, Math.max(.1, rx), Math.max(.1, ry), 0, 0, 7); ctx.fill(); }
  const font = (px, weight) => `${weight || ""} ${px}px Avenir Next,Avenir,system-ui,sans-serif`.trim();
  const CHALK = px => `${px}px "Chalkboard SE","Chalkboard","Marker Felt",sans-serif`;
  const glow = () => css("--rm-glow") || "255,190,120";
  const glowA = () => parseFloat(css("--rm-glow-a")) || .3;
  const night = () => css("--rm-night") === "1";

  // A cylinder standing at (cx, cy) tiles: rx wide (drawing units), z0 to z1 high, lit on the left.
  function cylinder(cx, cy, rx, z0, z1, base, topCol){
    const b = P(cx, cy, z0), t = P(cx, cy, z1), ry = rx/2, c = ctx;
    const g = c.createLinearGradient(b.x - rx, 0, b.x + rx, 0);
    g.addColorStop(0, lit(base, .12)); g.addColorStop(.45, base); g.addColorStop(1, dim(base, .3));
    c.fillStyle = g; c.beginPath(); c.moveTo(t.x - rx, t.y); c.lineTo(b.x - rx, b.y); c.ellipse(b.x, b.y, rx, ry, 0, Math.PI, 0, true); c.lineTo(t.x + rx, t.y); c.closePath(); c.fill();
    oval(t.x, t.y, rx, ry, topCol || lit(base, .18));
  }

  // ---------------------------------------------------------------- the room: floor and walls (cached)

  const layer = document.createElement("canvas");
  let layerKey = "";
  // The floor, walls, wall items, rugs and the shadows under furniture don't move, so they're drawn once into an
  // offscreen canvas and copied each frame. hide: an item left out (the one being dragged in the editor).
  function shell(room, desks, hide){
    const key = [themeGen, rot, straight, cv.width, cv.height, k, ox, oy, hide || "", !!draft, JSON.stringify(room), desks.map(d => d.x + "," + d.y + (d.extra ? "e" : "")).join(";")].join("|");
    if(key !== layerKey){
      layerKey = key;
      if(layer.width !== cv.width || layer.height !== cv.height){ layer.width = cv.width; layer.height = cv.height; }
      const keep = ctx;
      ctx = layer.getContext("2d");
      ctx.setTransform(1, 0, 0, 1, 0, 0); ctx.clearRect(0, 0, layer.width, layer.height);
      begin();
      try {
        drawFloor(room);
        const items = room.items.filter(it => CAT[it.kind] && it.id !== hide);
        for(const it of items) if(it.kind === "rug") drawRug(it);
        drawMat(room);
        drawDoormat(room);
        drawShadows(room, items, desks);
        drawWalls(room);
        for(const it of items) if(CAT[it.kind].zone === "wall") drawWallItem(it, 0, 1);
      } finally { ctx = keep; }
    }
    ctx.setTransform(1, 0, 0, 1, 0, 0); ctx.drawImage(layer, 0, 0); begin();
  }
  function begin(){ const d = devicePixelRatio; ctx.setTransform(k*d, 0, 0, k*d, ox*d, oy*d); }

  function drawFloor(room){
    const c = ctx, cols = room.cols, rows = room.rows, base = room.floor.color || hexv("--rm-floor", "#CD9C66");
    const edge = room.floor.color ? dim(base, .5) : hexv("--rm-slab", "#7A5536");
    // The floor's cut edge along the two near sides of the room.
    const A = rot % 2 ? rows - WR : cols, B = rot % 2 ? cols : rows - WR;
    if(straight) poly([P(0, rows, 0), P(cols, rows, 0), P(cols, rows, -SLAB), P(0, rows, -SLAB)], edge);
    else {
      poly([Q(0, B, 0), Q(A, B, 0), Q(A, B, -SLAB), Q(0, B, -SLAB)], edge);
      poly([Q(A, 0, 0), Q(A, B, 0), Q(A, B, -SLAB), Q(A, 0, -SLAB)], dim(edge, .3));
    }
    onFloor(() => {
      const y0 = WR*T, x1 = cols*T, y1 = rows*T, style = room.floor.style;
      c.save(); c.beginPath(); c.rect(0, y0, x1, y1 - y0); c.clip();
      const tone = n => { const v = (n % 9 - 4)/100; return v < 0 ? dim(base, -v*1.5) : lit(base, v*1.5); };
      if(style === "carpet"){
        c.fillStyle = base; c.fillRect(0, y0, x1, y1 - y0);
        c.fillStyle = dim(base, .08);
        for(let y = y0 + 4; y < y1; y += 8) for(let x = 4 + (y/8 % 2)*4; x < x1; x += 8) c.fillRect(x, y, 2.2, 2.2);
        c.fillStyle = dim(base, .12); for(let y = y0; y < y1; y += 2*T) c.fillRect(0, y, x1, 1);
      } else {
        c.fillStyle = dim(base, .32); c.fillRect(0, y0, x1, y1 - y0);   // shows between the boards as seams
        if(style === "wood"){
          // Long boards along the back wall, four to a tile, ends staggered.
          for(let y = y0, row = 0; y < y1; y += 10, row++){
            let x = -(hash2(row, 7) % 120);
            for(let i = 0; x < x1; i++){
              const len = 80 + hash2(row, i) % 110;
              c.fillStyle = tone(hash2(i, row + 99)); c.fillRect(x + .8, y + .6, len - 1.6, 8.8);
              x += len;
            }
          }
        } else {
          // Parquet: each tile is four short boards, turned the other way on alternate tiles.
          for(let ty = WR; ty < rows; ty++) for(let tx = 0; tx < cols; tx++){
            const along = (tx + ty) % 2 === 0, px = tx*T, py = ty*T;
            for(let i = 0; i < 4; i++){
              c.fillStyle = tone(hash2(tx*7 + i, ty*13 + i));
              if(along) c.fillRect(px + .7, py + i*10 + .6, T - 1.4, 8.8); else c.fillRect(px + i*10 + .6, py + .7, 8.8, T - 1.4);
            }
          }
        }
      }
      // Sunlight (or moonlight) through the windows, falling into the room.
      const sun = css("--rm-sun");
      if(sun && sun !== "none") for(const w of room.items) if(w.kind === "window"){
        for(const half of [0, 1]){
          const xa = w.x*T + 10 + half*(1.5*T - 2), xb = xa + 1.5*T - 18, yb = y0 + 2.8*T, sh = 1.2*T;
          const g = c.createLinearGradient(0, y0, 0, yb); g.addColorStop(0, sun); g.addColorStop(1, "rgba(255,255,255,0)");
          c.fillStyle = g; c.beginPath(); c.moveTo(xa, y0); c.lineTo(xb, y0); c.lineTo(xb + sh, yb); c.lineTo(xa + sh, yb); c.closePath(); c.fill();
        }
      }
      // The front of the room, where the queue and your desk are, behind a threshold strip.
      const ft = (rows - RoomModel.FRONT_ROWS)*T;
      c.fillStyle = "rgba(30,15,0,.06)"; c.fillRect(0, ft, x1, y1 - ft);
      c.fillStyle = hexv("--rm-trim", "#6E4B33"); c.fillRect(0, ft - 2, x1, 4);
      c.restore();
    });
    // Darker where the floor meets the walls: the back wall and both sides straight on, the two far walls angled.
    if(straight) onFloor(() => {
      const y0 = WR*T, x1 = cols*T, y1 = rows*T;
      let g = c.createLinearGradient(0, y0, 0, y0 + 44); g.addColorStop(0, "rgba(20,10,0,.28)"); g.addColorStop(1, "rgba(20,10,0,0)");
      c.fillStyle = g; c.fillRect(0, y0, x1, 44);
      for(const [xa, xb] of [[0, 30], [x1, x1 - 30]]){ g = c.createLinearGradient(xa, 0, xb, 0); g.addColorStop(0, "rgba(20,10,0,.2)"); g.addColorStop(1, "rgba(20,10,0,0)"); c.fillStyle = g; c.fillRect(Math.min(xa, xb), y0, 30, y1 - y0); }
    });
    else onFloorTurned(() => {
      let g = c.createLinearGradient(0, 0, 0, 44); g.addColorStop(0, "rgba(20,10,0,.26)"); g.addColorStop(1, "rgba(20,10,0,0)");
      c.fillStyle = g; c.fillRect(0, 0, A*T, 44);
      g = c.createLinearGradient(0, 0, 44, 0); g.addColorStop(0, "rgba(20,10,0,.22)"); g.addColorStop(1, "rgba(20,10,0,0)");
      c.fillStyle = g; c.fillRect(0, 0, 44, B*T);
    });
  }
  // The two far walls in this view: n is the wall's face toward the room, at its x or y, s0..s1 its extent along
  // the face (see face()), side "a" or "b" for which way it faces, back whether it's the back wall (the one with
  // the wall items). The two near walls are cut away.
  function farWalls(room){
    if(straight) return [{n:"y+", at:WR, s0:0, s1:room.cols, back:true, side:"f"}];
    const all = [{n:"y+", at:WR, s0:0, s1:room.cols, back:true}, {n:"x+", at:0, s0:-room.rows, s1:-WR}, {n:"x-", at:room.cols, s0:WR, s1:room.rows}, {n:"y-", at:room.rows, s0:-room.cols, s1:0}];
    return all.map(w => ({...w, side:facing(w.n)})).filter(w => w.side);
  }
  // Where a plain wall's lights are, along its face (see face()).
  const sconces = w => { const len = w.s1 - w.s0, n = Math.max(2, Math.round(len/6)); return Array.from({length:n}, (_, i) => w.s0 + len*(i + .5)/n); };
  // A point on a wall's face, in tiles, from its position along the face.
  const wallPoint = (w, s) => w.n === "y+" ? [s, w.at] : w.n === "x+" ? [w.at, -s] : w.n === "x-" ? [w.at, s] : [-s, w.at];
  function drawWalls(room){
    const c = ctx, cols = room.cols, rows = room.rows;
    const base = room.wall.color || hexv("--rm-wall", "#ECE2CF"), trim = hexv("--rm-trim", "#6E4B33");
    const wain = room.wall.color ? dim(room.wall.color, .28) : hexv("--rm-wain", "#98AE93");
    const wallFace = (l0, l1, shade, cornerX) => {
      const w = l1 - l0, wh = Math.round(WALLH*.33);
      const g = c.createLinearGradient(0, -WALLH, 0, 0); g.addColorStop(0, dim(base, shade + .1)); g.addColorStop(1, dim(base, shade));
      c.fillStyle = g; c.fillRect(l0, -WALLH, w, WALLH);
      // Wainscot boards under a rail, then the skirting board.
      const wc = dim(wain, shade);
      c.fillStyle = wc; c.fillRect(l0, -wh, w, wh);
      c.fillStyle = dim(wc, .16); for(let x = l0 + 8; x < l1; x += 8) c.fillRect(x, -wh, .9, wh);
      c.fillStyle = lit(wc, .1); for(let x = l0 + 9; x < l1; x += 8) c.fillRect(x, -wh, .5, wh);
      c.fillStyle = "rgba(0,0,0,.18)"; c.fillRect(l0, -wh, w, 2);
      c.fillStyle = dim(trim, shade); c.fillRect(l0, -wh - 5, w, 5); c.fillStyle = lit(trim, .25); c.fillRect(l0, -wh - 5, w, 1.2);
      c.fillStyle = dim(trim, shade); c.fillRect(l0, -9, w, 9); c.fillStyle = lit(trim, .22); c.fillRect(l0, -9, w, 1.4);
      c.fillStyle = "rgba(0,0,0,.08)"; c.fillRect(l0, -WALLH, w, 5);
      // Shadow into the corner.
      const cg = c.createLinearGradient(cornerX, 0, cornerX + (cornerX === l0 ? 40 : -40), 0);
      cg.addColorStop(0, "rgba(10,5,0,.22)"); cg.addColorStop(1, "rgba(10,5,0,0)");
      c.fillStyle = cg; c.fillRect(l0, -WALLH, w, WALLH);
    };
    // A wall facing the front right is in shade; the corner where the far walls meet is at the left end of a wall
    // facing the front left and the right end of the other.
    for(const w of farWalls(room)){
      face(w.n, w.at, () => {
        const shade = w.side === "a" ? .12 : 0;
        wallFace(w.s0*HW, w.s1*HW, shade, w.side === "b" ? w.s0*HW : w.s1*HW);
        if(w.back) return;
        for(const s of sconces(w)){
          const lx = s*HW, z = WALLH*.62, brass = "#B8913E";
          box(lx - 4, -z - 9, 8, 14, 2, dim(brass, .2));
          c.fillStyle = night() ? "#FBE3AE" : "#EFE3C8";
          c.beginPath(); c.moveTo(lx - 9, -z + 2); c.lineTo(lx - 6, -z - 12); c.lineTo(lx + 6, -z - 12); c.lineTo(lx + 9, -z + 2); c.closePath(); c.fill();
          c.fillStyle = "rgba(120,80,30,.2)"; c.beginPath(); c.moveTo(lx + 2, -z - 12); c.lineTo(lx + 6, -z - 12); c.lineTo(lx + 9, -z + 2); c.lineTo(lx + 3, -z + 2); c.closePath(); c.fill();
        }
      });
    }
    const cap = lit(base, .35), end = dim(base, .3);
    if(straight){
      // The corner by the right side wall, shaded like the left one; the back wall's top; the side walls, seen
      // end-on from the front as their tops and their cut ends.
      face("y+", WR, () => { const g = c.createLinearGradient(cols*HW, 0, cols*HW - 40, 0); g.addColorStop(0, "rgba(10,5,0,.22)"); g.addColorStop(1, "rgba(10,5,0,0)"); c.fillStyle = g; c.fillRect(cols*HW - 40, -WALLH, 40, WALLH); });
      poly([P(-SIDE, WR - THICK, WALLH), P(cols + SIDE, WR - THICK, WALLH), P(cols + SIDE, WR, WALLH), P(-SIDE, WR, WALLH)], cap);
      for(const [xa, xb] of [[-SIDE, 0], [cols, cols + SIDE]]){
        poly([P(xa, WR, WALLH), P(xb, WR, WALLH), P(xb, rows, WALLH), P(xa, rows, WALLH)], cap);
        poly([P(xa, rows, WALLH), P(xb, rows, WALLH), P(xb, rows, -SLAB), P(xa, rows, -SLAB)], end);
        c.fillStyle = "rgba(0,0,0,.18)"; const e = P(xa === 0 || xa > 0 ? xa : xb, WR, WALLH); c.fillRect(xa >= 0 ? e.x : e.x - 1.2, e.y, 1.2, P(0, rows, WALLH).y - e.y);
      }
      return;
    }
    // The walls' thickness, seen on top and at the cut ends, in the turned frame.
    const A = rot % 2 ? rows - WR : cols, B = rot % 2 ? cols : rows - WR;
    poly([Q(-THICK, -THICK, WALLH), Q(A, -THICK, WALLH), Q(A, 0, WALLH), Q(0, 0, WALLH)], cap);
    poly([Q(-THICK, -THICK, WALLH), Q(0, 0, WALLH), Q(0, B, WALLH), Q(-THICK, B, WALLH)], cap);
    poly([Q(A, -THICK, -SLAB), Q(A, 0, -SLAB), Q(A, 0, WALLH), Q(A, -THICK, WALLH)], end);
    poly([Q(-THICK, B, -SLAB), Q(0, B, -SLAB), Q(0, B, WALLH), Q(-THICK, B, WALLH)], dim(base, .18));
  }
  // Rugs and the needs-you mat lie flat on the floor.
  function drawRug(it){
    const c = ctx, px = it.x*T, py = it.y*T, w = CAT.rug.w*T, h = CAT.rug.h*T, rug = hexv("--rm-rug", "#C3684A"), rug2 = hexv("--rm-rug2", "#EEDCB6");
    onFloor(() => {
      c.fillStyle = "rgba(0,0,0,.1)"; c.beginPath(); c.roundRect(px + 3, py + 3, w - 6, h - 6, 12); c.fill();
      box(px + 6, py + 6, w - 12, h - 12, 10, rug);
      c.strokeStyle = rug2; c.lineWidth = 4; c.beginPath(); c.roundRect(px + 14, py + 14, w - 28, h - 28, 6); c.stroke();
      c.lineWidth = 1.5; c.beginPath(); c.roundRect(px + 21, py + 21, w - 42, h - 42, 4); c.stroke();
      c.fillStyle = alpha(rug2, .55);
      for(let x = px + 40; x < px + w - 30; x += 26) for(let y = py + 40; y < py + h - 30; y += 26){ c.beginPath(); c.moveTo(x, y - 6); c.lineTo(x + 6, y); c.lineTo(x, y + 6); c.lineTo(x - 6, y); c.closePath(); c.fill(); }
      c.strokeStyle = rug2; c.lineWidth = 1.2; c.beginPath();
      for(let y = py + 12; y < py + h - 10; y += 4){ c.moveTo(px + 6, y); c.lineTo(px + 1, y); c.moveTo(px + w - 6, y); c.lineTo(px + w - 1, y); }
      c.stroke();
    });
  }
  let matLabel = null;
  function drawMat(room){
    const c = ctx, geo = frontOf(room), x = 120, y = geo.matTop, w = room.cols*T - 240, h = geo.matBottom - geo.matTop;
    const mat = hexv("--rm-mat", "#F8D978"), edge = hexv("--rm-mat2", "#E0A800");
    onFloor(() => {
      c.fillStyle = "rgba(0,0,0,.12)"; c.beginPath(); c.roundRect(x - 2, y - 2, w + 4, h + 4, 18); c.fill();
      box(x, y, w, h, 16, mat);
      c.strokeStyle = edge; c.lineWidth = 3; c.beginPath(); c.roundRect(x + 8, y + 8, w - 16, h - 16, 10); c.stroke();
      c.setLineDash([2, 6]); c.lineWidth = 1.5; c.beginPath(); c.roundRect(x + 14, y + 14, w - 28, h - 28, 7); c.stroke(); c.setLineDash([]);
    });
    // Painted on the mat, reading along it from its left end in this view.
    // Straight on, the queue stands on the back half of the mat, so the lettering goes along the front half.
    matLabel = floorText("Needs you", x + 30, x + w - 30, straight ? y + h - 27 : y + h/2, font(30, 700), hexv("--rm-mat-ink", "#5A4300"), "start");
  }
  // Text painted on the floor along the room's x axis, turned so it reads left to right in this view. It starts at
  // whichever of x0, x1 (room units) is on the left ("start") or ends at whichever is on the right ("end"), centred
  // on y. Returns the screen box it covers.
  function floorText(text, x0, x1, y, f, colour, align){
    const c = ctx, flip = P(1, 0).x < P(0, 0).x;
    c.font = f;
    const w = c.measureText(text).width, left = flip ? x1 : x0, right = flip ? x0 : x1;
    const at = align === "start" ? left : right, dir = flip ? -1 : 1, from = align === "start" ? at : at - dir*w;
    onFloor(() => {
      c.save(); c.translate(at, y); if(flip) c.rotate(Math.PI);
      c.fillStyle = colour; c.font = f; c.textAlign = align === "start" ? "left" : "right"; c.textBaseline = "middle";
      c.fillText(text, 0, 0); c.restore();
    });
    const pts = [R(from, y - 16), R(from, y + 16), R(from + dir*w, y - 16), R(from + dir*w, y + 16)];
    const xs = pts.map(p => p.x), ys = pts.map(p => p.y);
    return {x:Math.min(...xs) - 4, y:Math.min(...ys) - 4, w:Math.max(...xs) - Math.min(...xs) + 8, h:Math.max(...ys) - Math.min(...ys) + 8};
  }
  // A mat inside the door, so arrivals and departures make sense when the back wall is cut away.
  function drawDoormat(room){
    const d = room.items.find(it => it.kind === "door");
    if(!d) return;
    onFloor(() => {
      box((d.x + .45)*T, WR*T + 4, 2.1*T, .75*T, 4, "#5A4A3A");
      ctx.strokeStyle = "rgba(255,240,210,.25)"; ctx.lineWidth = 1.5; ctx.beginPath(); ctx.roundRect((d.x + .45)*T + 4, WR*T + 8, 2.1*T - 8, .75*T - 8, 3); ctx.stroke();
    });
  }
  // Soft contact shadows under everything that stands on the floor.
  function drawShadows(room, items, desks){
    const c = ctx, col = css("--rm-shadow") || "rgba(0,0,0,.08)";
    const soft = (x0, y0, x1, y1, r) => { c.fillStyle = col; for(let i = 0; i < 3; i++){ c.beginPath(); c.roundRect(x0*T - i*3, y0*T - i*3 + 2, (x1 - x0)*T + i*6, (y1 - y0)*T + i*6, r + i*3); c.fill(); } };
    onFloor(() => {
      for(const d of desks){ soft(d.x + .12, d.y + .1, d.x + 2.88, d.y + 1.08, 4); soft(d.x + 1.18, d.y + 1.2, d.x + 1.82, d.y + 1.78, 10); }
      for(const it of items){
        const cat = CAT[it.kind];
        if(cat.zone !== "floor" || it.kind === "rug" || it.kind === "desk") continue;
        const round = it.kind === "plant" || it.kind === "globe" || it.kind === "lamp" || it.kind === "beanbag";
        if(round){ const cx = (it.x + cat.w/2)*T, cy = (it.y + cat.h/2)*T, r = it.kind === "plant" || it.kind === "lamp" ? 12 : cat.w*T*.36; c.fillStyle = col; for(let i = 0; i < 3; i++){ c.beginPath(); c.arc(cx, cy, r + i*4, 0, 7); c.fill(); } }
        else soft(it.x + .08, it.y + .1, it.x + cat.w - .08, it.y + cat.h - .06, 6);
      }
      const x0 = (W/2 - 220)/T, x1 = (W/2 + 220)/T;
      soft(x0, room.rows - 1.15, x1, room.rows - .25, 4);
    });
  }

  // ---------------------------------------------------------------- wall items

  // Wall items, on the back wall's face. part: 1 draws what never changes, 2 what does (the board's chalk, the
  // clock's hands, the door), 3 both.
  let doorLabel = null;
  function drawWallItem(it, t, part){
    const c = ctx, cat = CAT[it.kind], cw = cat.w*HW, ch = cat.h*WZ, px = it.x*HW, py = wy(it.y);
    const frame = hexv("--rm-frame", "#F6F1E7"), wood2 = hexv("--rm-wood2", "#875A3B");
    onWall(() => {
      if(it.kind === "window" && part & 1){
        box(px + 6, py + 6, cw - 10, ch - 10, 3, "rgba(0,0,0,.2)");
        box(px + 4, py + 3, cw - 8, ch - 10, 3, frame);
        const gx = px + 10, gy = py + 9, gw = cw - 20, gh = ch - 26;
        const g = c.createLinearGradient(0, gy, 0, gy + gh);
        g.addColorStop(0, hexv("--rm-sky", "#79BCE6")); g.addColorStop(.62, hexv("--rm-sky2", "#BCE0F3")); g.addColorStop(1, hexv("--rm-sky3", "#EAF4EC"));
        box(gx, gy, gw, gh, 1.5, g);
        c.save(); c.beginPath(); c.rect(gx, gy, gw, gh); c.clip();
        if(night()){
          c.fillStyle = "rgba(255,250,235,.85)";
          for(let i = 0; i < 7; i++){ const h = hash2(it.x*31 + i, i*17 + 3); c.fillRect(gx + h % gw, gy + (h >>> 8) % (gh*.55), 1.3, 1.3); }
          if(hash(it.id) % 2 === 0){ oval(gx + gw*.7, gy + gh*.26, 6, 6, "#F4EBCF"); oval(gx + gw*.7 + 2.5, gy + gh*.26 - 1.5, 5, 5, hexv("--rm-sky", "#141A3C")); }
          // Far-off rooftops against the last light.
          c.fillStyle = "rgba(15,12,30,.75)";
          for(let x = gx, i = 0; x < gx + gw; i++){ const bw = 8 + hash2(it.x, i) % 12, bh = 4 + hash2(i, it.x) % 10; c.fillRect(x, gy + gh - bh, bw - 1, bh); x += bw; }
        } else {
          c.fillStyle = "rgba(255,255,255,.85)";
          const cx = gx + 14 + hash(it.id) % (gw - 30), cy = gy + 12;
          for(const [dx, dy, r] of [[0, 0, 6], [7, -3, 7], [14, 0, 5.5], [7, 2, 6]]){ c.beginPath(); c.arc(cx + dx, cy + dy, r, 0, 7); c.fill(); }
          c.fillStyle = "rgba(80,130,90,.55)";
          for(let x = gx, i = 0; x < gx + gw; i++){ const r = 6 + hash2(it.x, i) % 6; c.beginPath(); c.arc(x + r, gy + gh + 2, r, Math.PI, 0); c.fill(); x += r*1.6; }
        }
        c.fillStyle = "rgba(255,255,255,.12)"; c.beginPath(); c.moveTo(gx + gw*.15, gy + gh); c.lineTo(gx + gw*.42, gy); c.lineTo(gx + gw*.55, gy); c.lineTo(gx + gw*.28, gy + gh); c.fill();
        c.restore();
        c.fillStyle = "rgba(0,0,0,.18)"; c.fillRect(gx, gy, gw, 2.5);
        c.fillStyle = frame; c.fillRect(gx + gw/2 - 1.6, gy, 3.2, gh); c.fillRect(gx, gy + gh*.44, gw, 2.8);
        box(px + 1, py + ch - 15, cw - 2, 6, 1.5, lit(frame, .2));
        c.fillStyle = "rgba(0,0,0,.16)"; c.fillRect(px + 3, py + ch - 9, cw - 6, 3);
      } else if(it.kind === "board"){
        const sx = px + 12, sy = py + 14, sw = cw - 24, sh = ch - 36;
        if(part & 1){
          box(px + 7, py + 8, cw - 10, ch - 18, 5, "rgba(0,0,0,.22)");
          box(px + 5, py + 6, cw - 10, ch - 20, 5, wood2);
          c.fillStyle = lit(wood2, .25); c.fillRect(px + 8, py + 6.5, cw - 16, 1.4);
          const slate = hexv("--rm-board", "#2F4B40"), g = c.createLinearGradient(sx, sy, sx + sw*.4, sy + sh*1.6);
          g.addColorStop(0, lit(slate, .07)); g.addColorStop(1, dim(slate, .14));
          box(sx, sy, sw, sh, 2, g);
          c.strokeStyle = "rgba(255,255,255,.045)"; c.lineWidth = 12; c.lineCap = "round";
          for(let i = 0; i < 4; i++){ const h = hash2(it.x + i, 5); c.beginPath(); c.arc(sx + 30 + h % (sw - 60), sy + sh*.5 + (h >>> 9) % 20, 26 + (h >>> 4) % 30, Math.PI*1.1, Math.PI*1.7); c.stroke(); }
          c.fillStyle = "rgba(0,0,0,.25)"; c.fillRect(sx, sy, sw, 2);
          // The chalk tray, with chalk and the eraser.
          box(px + 3, py + ch - 20, cw - 6, 7, 1.5, lit(wood2, .12));
          c.fillStyle = "rgba(0,0,0,.2)"; c.fillRect(px + 5, py + ch - 13, cw - 10, 2.5);
          for(const [dx, col] of [[40, "#F4F2EA"], [52, "#F4E07A"], [61, "#F2A7B4"]]) box(px + dx, py + ch - 23, 8, 3.2, 1.5, col);
          box(px + cw - 64, py + ch - 26, 22, 7, 1.5, "#3A3A44"); box(px + cw - 64, py + ch - 26, 22, 3, 1.5, lit(wood2, .3));
        }
        if(part & 2){
          // The date and the counts, in chalk.
          const mid = sx + sw/2, step = Math.min(130, sw*.3), n = board?.counts || {}, chalk = hexv("--rm-chalk", "#F1F4EC");
          c.textAlign = "center"; c.fillStyle = chalk; c.globalAlpha = .92; c.font = CHALK(16);
          c.fillText(fit(new Date().toLocaleDateString([], {weekday:"long", month:"long", day:"numeric"}), sw - 30), mid, sy + 22);
          [[n.needs || 0, "need you", "#F7C948", mid - step], [n.working || 0, "working", chalk, mid], [n.idle || 0, "idle", chalk, mid + step]].forEach(([v, label, col, x]) => {
            c.fillStyle = col; c.font = CHALK(38); c.fillText(v, x, sy + 58);
            c.font = CHALK(16); c.fillText(label, x, sy + 79);
          });
          c.globalAlpha = 1;
        }
      } else if(it.kind === "clock"){
        const cx = px + cw/2, cy = py + ch/2, r = 14;
        if(part & 1){
          oval(cx + 1.5, cy + 2, r + 2, r + 2, "rgba(0,0,0,.2)");
          oval(cx, cy, r + 2.5, r + 2.5, hexv("--rm-dark", "#2B2F3A"));
          oval(cx, cy, r, r, "#FBF7EC");
          c.fillStyle = "#3A3A44";
          for(let i = 0; i < 12; i++){ const a = i/12*Math.PI*2, l = i % 3 ? 1.6 : 3; c.save(); c.translate(cx + Math.sin(a)*(r - 2.5), cy - Math.cos(a)*(r - 2.5)); c.rotate(a); c.fillRect(-.6, -l/2, 1.2, l); c.restore(); }
        }
        if(part & 2){
          const d = new Date(); c.strokeStyle = "#22242C"; c.lineCap = "round";
          for(const [ang, len, lw] of [[(d.getHours() % 12 + d.getMinutes()/60)/12, 7, 2.2], [d.getMinutes()/60, 10.5, 1.5]]){ const a = ang*2*Math.PI; c.lineWidth = lw; c.beginPath(); c.moveTo(cx, cy); c.lineTo(cx + len*Math.sin(a), cy - len*Math.cos(a)); c.stroke(); }
          oval(cx, cy, 1.6, 1.6, "#C9562F");
        }
      } else if(it.kind === "poster" && part & 1){
        const col = BODY[hash(it.id) % BODY.length];
        box(px + 9, py + 8, cw - 14, ch - 14, 2, "rgba(0,0,0,.18)");
        box(px + 7, py + 6, cw - 14, ch - 14, 2, "#FBF6EA");
        box(px + 12, py + 11, cw - 24, ch - 40, 1.5, lit(col, .15));
        c.fillStyle = dim(col, .1); hex(px + cw/2, py + 11 + (ch - 40)/2, 12); c.fill();
        c.fillStyle = "#FBF6EA"; hex(px + cw/2, py + 11 + (ch - 40)/2, 8); c.fill();
        for(let i = 0; i < 3; i++) box(px + 12, py + ch - 25 + i*5, (cw - 24)*(i === 2 ? .5 : i ? .75 : 1), 2.2, 1, "#B8AE98");
        oval(px + cw/2, py + 9, 2.4, 2.4, "#C9562F");
      } else if(it.kind === "door"){
        const dx = px + 15, dw = cw - 30, top = -142;
        if(part & 1){
          box(dx - 7, top - 7, dw + 14, -top + 7, 2, hexv("--rm-trim", "#6E4B33"));
          c.fillStyle = lit(hexv("--rm-trim", "#6E4B33"), .25); c.fillRect(dx - 7, top - 7, dw + 14, 1.5);
          box(dx - 7, top - 30, dw + 14, 20, 2, hexv("--rm-trim", "#6E4B33"));
          box(dx - 3, top - 27, dw + 6, 14, 1, night() ? "#F2C77C" : hexv("--rm-sky2", "#BCE0F3"));
          c.fillStyle = hexv("--rm-trim", "#6E4B33"); for(let i = 1; i < 4; i++) c.fillRect(dx - 3 + i*(dw + 6)/4 - .8, top - 27, 1.6, 14);
        }
        if(part & 2){
          const open = !draft && G && [...agents.values()].some(a => Math.hypot(a.x - G.door.x, a.y - G.door.y) < 80);
          if(open){
            const g = c.createLinearGradient(0, top, 0, 0); g.addColorStop(0, "#2A2018"); g.addColorStop(1, "#6B4E2E");
            box(dx, top, dw, -top, 1, g);
            c.fillStyle = "rgba(255,214,150,.25)"; c.fillRect(dx + dw*.3, top + 10, dw*.4, -top - 10);
          } else {
            const door = hexv("--rm-door", "#9B6B45");
            box(dx, top, dw, -top, 1, door);
            c.strokeStyle = dim(door, .3); c.lineWidth = 1.4;
            c.strokeRect(dx + 8, top + 52, dw - 16, 34); c.strokeRect(dx + 8, top + 94, dw - 16, -top - 104);
            box(dx + 10, top + 10, dw - 20, 34, 1.5, night() ? "#E9B970" : hexv("--rm-sky2", "#BCE0F3"));
            c.fillStyle = dim(door, .3); c.fillRect(dx + dw/2 - .8, top + 10, 1.6, 34);
            oval(dx + dw - 9, top + 82, 3.2, 3.2, "#D9B45A"); oval(dx + dw - 9.6, top + 81.3, 1.2, 1.2, "#FFF1C2");
          }
        }
      }
    });
  }
  // How many went home today: above the door, facing you, or by the doormat when the back wall is cut away.
  // Drawn with the rest of the text, so furniture never covers it.
  function doorCount(room){
    const it = room.items.find(i => i.kind === "door");
    doorLabel = null;
    if(!it) return;
    const c = ctx, at = backShown() ? P(it.x + CAT.door.w/2, WR, WALLH + (straight ? 16 : 46)) : P(it.x + CAT.door.w/2, WR + .4, 30), ts = textScale(), text = `${board?.counts?.ended || 0} went home`;
    c.font = font(Math.round(12*ts), 600); c.textAlign = "center";
    const w = c.measureText(text).width;
    if(!backShown()) box(at.x - w/2 - 6, at.y - 13*ts, w + 12, 17*ts, 5, alpha(hexv("--rm-panel", "#FFFDF8"), .85));
    c.fillStyle = css("--ink2"); c.fillText(text, at.x, at.y);
    doorLabel = {x:at.x - w/2 - 6, y:at.y - 14*ts, w:w + 12, h:18*ts};
  }
  // The board's area on screen, so text never covers it.
  function boardRect(it){
    const a = P(it.x, WR, (WR - it.y)*WZ), b = P(it.x + CAT.board.w, WR, (WR - it.y - CAT.board.h)*WZ);
    return {x:a.x, y:a.y, w:b.x - a.x, h:b.y - a.y};
  }

  // ---------------------------------------------------------------- furniture

  // Every desk has a chair. A desk's screen and lamp are on while its session is working, and dark otherwise.
  // Extra desks, added because the saved room has fewer desks than sessions, have a dashed outline.
  function drawDesk(slot, owner, t){
    const x = slot.x, y = slot.y, zt = 26, wood = hexv("--rm-wood", "#C28C58"), wood2 = hexv("--rm-wood2", "#875A3B"), metal = hexv("--rm-metal", "#4E5563"), dark = hexv("--rm-dark", "#2B2F3A");
    const st = owner?.s, on = st?.group === "working", ask = st?.group === "needs";
    if(slot.extra) onFloor(() => { ctx.save(); ctx.setLineDash([8, 6]); ctx.strokeStyle = css("--ink2"); ctx.lineWidth = 2.5; ctx.beginPath(); ctx.roundRect(x*T + 2, y*T + 2, 3*T - 4, 2*T - 4, 6); ctx.stroke(); ctx.restore(); });
    // Under the top: a modesty panel at the back, two legs, and drawers on the right.
    inOrder([
      [x + 1.15, y + .18, () => prism(x + .24, y + .14, x + 2.06, y + .22, 6, zt - 4, dim(wood2, .1), {line:false})],
      [x + .23, y + .17, () => prism(x + .18, y + .12, x + .28, y + .22, 0, zt - 4, metal, {line:false})],
      [x + .23, y + .95, () => prism(x + .18, y + .9, x + .28, y + 1, 0, zt - 4, metal, {line:false})],
      [x + 2.43, y + .56, () => {
        prism(x + 2.04, y + .14, x + 2.82, y + .98, 0, zt - 4, wood2);
        faceY(y + .98, () => {
          const l0 = (x + 2.08)*HW, l1 = (x + 2.78)*HW;
          for(const z of [8, 15]){ ctx.fillStyle = dim(wood2, .35); ctx.fillRect(l0, -z, l1 - l0, .9); }
          for(const z of [4.5, 11.5, 18.5]) box((l0 + l1)/2 - 4, -z - 1, 8, 2, 1, lit(metal, .35));
        });
      }],
    ]);
    prism(x + .1, y + .06, x + 2.9, y + 1.06, zt - 4, zt, wood);
    // On top: something of its owner's, the screen (facing the chair), the keyboard and the lamp. Straight on, the
    // screen moves left and the keepsake right, so the sitter's head doesn't hide the screen.
    const kind = hash2(x, y) % 4, sx = x, mx = straight ? -.62 : 0, dx = straight ? 1.55 : 0;
    inOrder([
      [x + .5 + dx, y + .7, () => {
        const x = sx + dx;
        if(kind === 0){ prism(x + .3, y + .55, x + .72, y + .86, zt, zt + 3, BODY[(sx + y) % 8], {line:false}); prism(x + .34, y + .52, x + .7, y + .82, zt + 3, zt + 6, lit(BODY[(sx*3 + y) % 8], .1), {line:false}); }
        else if(kind === 1) cylinder(x + .5, y + .7, 4, zt, zt + 8, "#E9E2D2", "#6B4A33");
        else if(kind === 2){ cylinder(x + .48, y + .66, 5, zt, zt + 7, hexv("--rm-pot", "#C8693F")); const p = P(x + .48, y + .66, zt + 7); for(const [dx, dy] of [[-4, -6], [0, -9], [4, -6]]) oval(p.x + dx, p.y + dy, 3.2, 5, hexv("--rm-leaf2", "#80B657")); }
        else { const p = [P(x + .28, y + .48, zt + .5), P(x + .78, y + .48, zt + .5), P(x + .78, y + .92, zt + .5), P(x + .28, y + .92, zt + .5)]; poly(p, "#F6F2E8", "rgba(0,0,0,.15)", .6); }
      }],
      [x + 1.5 + mx, y + .4, () => {
        const x = sx + mx;
        prism(x + 1.3, y + .34, x + 1.7, y + .5, zt, zt + 1.5, metal, {line:false});
        prism(x + 1.46, y + .38, x + 1.54, y + .44, zt + 1.5, zt + 10, metal, {line:false});
        prism(x + .98, y + .34, x + 2.02, y + .42, zt + 8, zt + 33, dark, {line:dim(dark, .4)});
        faceY(y + .42, () => {
          const l0 = (x + 1.03)*HW, w = .94*HW, top = -(zt + 31), h = 21;
          if(on){
            const g = ctx.createLinearGradient(0, top, 0, top + h); g.addColorStop(0, lit(hexv("--work", "#0B7480"), .35)); g.addColorStop(1, hexv("--work", "#0B7480"));
            box(l0, top, w, h, 1, g);
            ctx.save(); ctx.beginPath(); ctx.rect(l0, top, w, h); ctx.clip();
            const scroll = (t*6 + (owner?.seed || 0)) % 4;
            for(let i = -1; i < 6; i++){ const len = 6 + hash2(i + Math.floor(t*1.5), x) % 18; ctx.fillStyle = i % 3 ? "rgba(255,255,255,.75)" : "rgba(255,230,150,.85)"; ctx.fillRect(l0 + 3 + (i % 2)*3, top + 3 + i*4 - scroll, len, 1.6); }
            ctx.restore();
          } else {
            box(l0, top, w, h, 1, ask ? "#5A4710" : "#1A1D26");
            ctx.fillStyle = "rgba(255,255,255,.07)"; ctx.beginPath(); ctx.moveTo(l0 + 4, top + h); ctx.lineTo(l0 + 12, top); ctx.lineTo(l0 + 17, top); ctx.lineTo(l0 + 9, top + h); ctx.fill();
            if(ask){ ctx.fillStyle = "#F5B700"; ctx.font = font(13, 700); ctx.textAlign = "center"; ctx.fillText("?", l0 + w/2, top + h - 5); }
          }
        });
      }],
      [x + 1.5, y + .71, () => prism(x + 1.08, y + .62, x + 1.92, y + .8, zt, zt + 1.4, lit(dark, .25), {line:false})],
      [x + 2.58, y + .3, () => {
        const b = P(x + 2.58, y + .3, zt), sh = {x:b.x - 10, y:b.y - 25};
        oval(b.x, b.y, 5.5, 2.7, dim(metal, .1));
        ctx.strokeStyle = metal; ctx.lineWidth = 1.8; ctx.lineCap = "round";
        ctx.beginPath(); ctx.moveTo(b.x, b.y - 1); ctx.lineTo(b.x + 2, b.y - 17); ctx.lineTo(sh.x + 3, sh.y + 1); ctx.stroke();
        ctx.fillStyle = on ? "#FFE3A8" : dim(metal, .1);
        ctx.beginPath(); ctx.moveTo(sh.x - 6, sh.y + 6); ctx.lineTo(sh.x + 5, sh.y - 3); ctx.lineTo(sh.x + 8, sh.y + 2); ctx.lineTo(sh.x - 1, sh.y + 10); ctx.closePath(); ctx.fill();
        ctx.fillStyle = lit(metal, .15); ctx.beginPath(); ctx.moveTo(sh.x - 6, sh.y + 6); ctx.lineTo(sh.x + 5, sh.y - 3); ctx.lineTo(sh.x + 3, sh.y - 5); ctx.lineTo(sh.x - 7, sh.y + 2); ctx.closePath(); ctx.fill();
        if(on){ const g = ctx.createRadialGradient(sh.x - 1, sh.y + 8, 0, sh.x - 1, sh.y + 8, 9); g.addColorStop(0, "rgba(255,240,200,.95)"); g.addColorStop(1, "rgba(255,220,150,0)"); ctx.fillStyle = g; ctx.beginPath(); ctx.arc(sh.x - 1, sh.y + 8, 9, 0, 7); ctx.fill(); }
      }],
    ]);
  }
  // The chair, and its sitter when there is one: seat, then sitter, then the chair back in front of the sitter.
  function drawChair(slot, sitter, t){
    const cx = slot.x + 1.5, cy = slot.y + 1.45, chair = hexv("--rm-chair", "#4F7F8F"), metal = hexv("--rm-metal", "#4E5563");
    const base = P(cx, cy, 1);
    ctx.strokeStyle = dim(metal, .2); ctx.lineWidth = 2; ctx.lineCap = "round";
    for(const [dx, dy] of [[.3, 0], [-.3, 0], [0, .28], [0, -.28]]){ const e = P(cx + dx, cy + dy, 1); ctx.beginPath(); ctx.moveTo(base.x, base.y); ctx.lineTo(e.x, e.y); ctx.stroke(); oval(e.x, e.y + 1, 1.8, 1.2, "#1E2028"); }
    prism(cx - .04, cy - .04, cx + .04, cy + .04, 1, 13, metal, {line:false});
    prism(cx - .3, cy - .28, cx + .3, cy + .26, 13, 17, chair);
    const back = () => { prism(cx - .03, cy + .26, cx + .03, cy + .31, 14, 20, metal, {line:false}); prism(cx - .28, cy + .24, cx + .28, cy + .32, 20, 37, chair); };
    // The back is on the chair's south side: in front of the sitter in some views, behind in others.
    const nearBack = depth(cx, cy + 1) > depth(cx, cy);
    if(!nearBack) back();
    if(sitter) drawAgent(sitter, t, {seated:true});
    if(nearBack) back();
  }
  function drawStool(x, y){
    const p = R(x, y), wood = hexv("--rm-wood", "#C28C58");
    ctx.strokeStyle = hexv("--rm-wood2", "#875A3B"); ctx.lineWidth = 1.8;
    for(const dx of [-6, 0, 6]){ ctx.beginPath(); ctx.moveTo(p.x + dx*.9, p.y - 9); ctx.lineTo(p.x + dx*1.2, p.y + (dx ? -1 : 2)); ctx.stroke(); }
    oval(p.x, p.y - 9, 10, 5, dim(wood, .25)); oval(p.x, p.y - 10.5, 10, 5, wood);
  }
  function drawItem(it, t){
    const c = ctx, cat = CAT[it.kind], x = it.x, y = it.y, wood = hexv("--rm-wood", "#C28C58"), wood2 = hexv("--rm-wood2", "#875A3B"), dark = hexv("--rm-dark", "#2B2F3A"), metal = hexv("--rm-metal", "#4E5563");
    if(it.kind === "desk"){ drawDesk({x, y, extra:false}, null, t); drawChair({x, y}, null, t); return; }
    if(it.kind === "shelf"){
      // A low bookcase against the back wall, low enough to leave a window above it in view.
      const x0 = x + .06, x1 = x + cat.w - .06, y0 = y + .1, y1 = y + .9, zh = 42;
      prism(x0, y0, x1, y1, 0, zh, wood2);
      faceY(y1, () => {
        const l0 = x0*HW + 4, l1 = x1*HW - 4;
        for(const [b0, b1] of [[-zh + 4, -zh/2 - 1], [-zh/2 + 3, -4]]){
          box(l0, b0, l1 - l0, b1 - b0, 1, dim(wood2, .45));
          for(let lx = l0 + 1, i = 0; lx < l1 - 4; i++){
            const h = hash2(x*11 + i, b0), bw = 3 + h % 3, bh = (b1 - b0) - 1 - (h >>> 4) % 5;
            if((h >>> 9) % 11 === 0){ lx += 4; continue; }
            box(lx, b1 - bh, bw, bh, .6, mix(BODY[h % 8], "#E3D3B0", .28));
            ctx.fillStyle = "rgba(255,255,255,.35)"; ctx.fillRect(lx + .6, b1 - bh + 2, bw - 1.2, .8);
            lx += bw + .5;
          }
        }
      });
      prism(x0 - .04, y0 - .04, x1 + .04, y1 + .04, zh, zh + 3, wood);
      prism(x1 - .9, y0 + .2, x1 - .5, y0 + .55, zh + 3, zh + 6, BODY[(x + 2) % 8], {line:false});
      prism(x1 - .86, y0 + .24, x1 - .54, y0 + .52, zh + 6, zh + 9, BODY[(x + 5) % 8], {line:false});
    } else if(it.kind === "plant"){
      const cx = x + .5, cy = y + .5, top = P(cx, cy, 18);
      cylinder(cx, cy, 10, 0, 18, hexv("--rm-pot", "#C8693F"));
      oval(top.x, top.y, 8, 4, "#3A2A1E");
      const leaf = hexv("--rm-leaf", "#4C8A3B"), leaf2 = hexv("--rm-leaf2", "#80B657"), n = 7;
      for(let i = 0; i < n; i++){
        const h = hash2(x*13 + i, y*7), a = -Math.PI/2 + ((i/(n - 1)) - .5)*2.2 + ((h % 20) - 10)/60, len = 22 + h % 16;
        const ex = top.x + Math.cos(a)*len*.8, ey = top.y - 6 + Math.sin(a)*len;
        c.fillStyle = i % 2 ? leaf : leaf2;
        c.beginPath(); c.moveTo(top.x, top.y - 2);
        c.quadraticCurveTo(top.x + Math.cos(a - .5)*len*.6, top.y - 4 + Math.sin(a - .5)*len*.7, ex, ey);
        c.quadraticCurveTo(top.x + Math.cos(a + .5)*len*.6, top.y - 4 + Math.sin(a + .5)*len*.7, top.x, top.y - 2);
        c.fill();
        c.strokeStyle = "rgba(255,255,255,.2)"; c.lineWidth = .7; c.beginPath(); c.moveTo(top.x, top.y - 3); c.lineTo((top.x + ex)/2, (top.y + ey)/2); c.stroke();
      }
    } else if(it.kind === "globe"){
      const cx = x + 1, cy = y + 1, b = P(cx, cy, 0), s = P(cx, cy, 50), r = 19;
      cylinder(cx, cy, 15, 0, 5, wood2, lit(wood2, .2));
      prism(cx - .04, cy - .04, cx + .04, cy + .04, 5, 30, metal, {line:false});
      c.strokeStyle = "#B8913E"; c.lineWidth = 2.4; c.beginPath(); c.arc(s.x, s.y, r + 4, Math.PI*.55, Math.PI*1.95); c.stroke();
      const g = c.createRadialGradient(s.x - 7, s.y - 8, 2, s.x, s.y, r); g.addColorStop(0, "#7FC4EA"); g.addColorStop(1, "#1F6FA5");
      c.fillStyle = g; c.beginPath(); c.arc(s.x, s.y, r, 0, 7); c.fill();
      c.save(); c.beginPath(); c.arc(s.x, s.y, r, 0, 7); c.clip();
      const spin = (t*4) % 60;
      c.fillStyle = "#6FA64A";
      for(const [lx, ly, rx, ry] of [[-8, -7, 9, 6], [10, 4, 7, 9], [-2, 10, 6, 4], [-30, 2, 8, 7], [26, -8, 6, 5]]){ let px = lx + spin; if(px > 30) px -= 60; c.beginPath(); c.ellipse(s.x + px, s.y + ly, rx, ry, .4, 0, 7); c.fill(); }
      c.fillStyle = "rgba(0,0,0,.18)"; c.beginPath(); c.arc(s.x + 6, s.y + 5, r, 0, 7); c.arc(s.x, s.y, r, 0, 7, true); c.fill();
      c.restore();
      oval(s.x - 7, s.y - 8, 4, 2.6, "rgba(255,255,255,.45)");
      c.strokeStyle = "#D7B055"; c.lineWidth = 1.6; c.beginPath(); c.arc(s.x, s.y, r + 4, Math.PI*1.95, Math.PI*2.55); c.stroke();
      void b;
    } else if(it.kind === "machine"){
      // The machine where commands run: lights on the front, tape reels on the side that turn while it's in use.
      const x0 = x + .12, x1 = x + 1.88, y0 = y + .14, y1 = y + 2.86, zh = 78, busy = !draft && [...agents.values()].some(a => !a.path.length && a.dest?.kind === "run");
      prism(x0, y0, x1, y1, 0, zh, dark, {top:lit(dark, .2), right:dim(dark, .1), left:lit(dark, .08), line:dim(dark, .5)});
      prism(x0 - .04, y0 - .04, x1 + .04, y1 + .04, zh, zh + 4, lit(dark, .15), {line:false});
      const front = (n, at) => face(n, at, () => {
        const [s0, s1] = span(n, x0, y0, x1, y1), l0 = s0*HW + 6, w = (s1 - s0)*HW - 12;
        box(l0, -zh + 8, w, 18, 2, "#0E1A1C");
        ctx.fillStyle = hexv("--work", "#0B7480"); ctx.font = font(9, 700); ctx.textAlign = "left"; ctx.fillText((busy && Math.floor(t*2) % 2) ? ">_" : ">", l0 + 4, -zh + 20);
        for(let i = 0; i < 4; i++) for(let j = 0; j < 5; j++){
          const lightOn = calm.matches ? (i + j) % 3 === 0 : Math.sin(t*(2 + (i*j) % 3) + i*2 + j) > (busy ? -.2 : .4);
          box(l0 + 3 + j*(w - 6)/5, -zh + 34 + i*8, 4, 4, 1, lightOn ? (j % 3 ? hexv("--work", "#0B7480") : "#F5B700") : "#3A3F4A");
        }
        for(let i = 0; i < 4; i++){ ctx.fillStyle = "rgba(0,0,0,.35)"; ctx.fillRect(l0, -20 + i*4, w, 1.4); }
      });
      // The panel is on whichever end faces you, the reels on whichever side does.
      front("y+", y1) || front("y-", y0);
      const side = (n, at) => face(n, at, () => {
        const [s0, s1] = span(n, x0, y0, x1, y1), l0 = s0*HW + 8, l1 = s1*HW - 8;
        for(const [i, cxl] of [[0, l0 + (l1 - l0)*.3], [1, l0 + (l1 - l0)*.7]]){
          const cyl = -zh + 26;
          oval(cxl, cyl, 11, 11, "#C9CDD6"); oval(cxl, cyl, 9, 9, "#20232B"); oval(cxl, cyl, 3, 3, "#C9CDD6");
          ctx.strokeStyle = "#C9CDD6"; ctx.lineWidth = 1.4;
          const a0 = busy ? t*(i ? -3 : 3) : i;
          for(let s = 0; s < 3; s++){ const a = a0 + s*2.09; ctx.beginPath(); ctx.moveTo(cxl + Math.cos(a)*3, cyl + Math.sin(a)*3); ctx.lineTo(cxl + Math.cos(a)*8, cyl + Math.sin(a)*8); ctx.stroke(); }
        }
        for(let i = 0; i < 6; i++){ ctx.fillStyle = "rgba(255,255,255,.07)"; ctx.fillRect(l0, -34 + i*5, l1 - l0, 2); }
      });
      side("x+", x1) || side("x-", x0);
    } else if(it.kind === "fountain"){
      const cx = x + .5, cy = y + 1;
      prism(cx - .32, cy - .3, cx + .32, cy + .3, 0, 40, "#E4E6EA", {line:"#8F949E"});
      faceY(cy + .3, () => { box((cx - .14)*HW, -30, .28*HW, 8, 1.5, "#3B4150"); box((cx - .05)*HW, -24, .1*HW, 4, .8, "#2E8BC7"); });
      const b = P(cx, cy, 40), t2 = P(cx, cy, 66);
      c.fillStyle = "rgba(120,190,235,.75)"; c.beginPath(); c.moveTo(b.x - 9, b.y); c.lineTo(t2.x - 9, t2.y + 4); c.quadraticCurveTo(t2.x, t2.y - 6, t2.x + 9, t2.y + 4); c.lineTo(b.x + 9, b.y); c.closePath(); c.fill();
      c.fillStyle = "rgba(255,255,255,.4)"; c.fillRect(b.x - 6, t2.y + 6, 2.5, b.y - t2.y - 8);
      oval(b.x, b.y - 6, 9, 4, "rgba(80,150,205,.5)");
    } else if(it.kind === "beanbag"){
      const p = P(x + .5, y + .5, 0), col = BODY[hash(it.id) % BODY.length];
      const g = c.createRadialGradient(p.x - 5, p.y - 16, 2, p.x, p.y - 8, 20); g.addColorStop(0, lit(col, .25)); g.addColorStop(1, dim(col, .25));
      c.fillStyle = g; c.beginPath(); c.moveTo(p.x - 17, p.y - 2); c.quadraticCurveTo(p.x - 19, p.y - 18, p.x - 4, p.y - 22); c.quadraticCurveTo(p.x + 10, p.y - 26, p.x + 16, p.y - 12); c.quadraticCurveTo(p.x + 20, p.y + 2, p.x, p.y + 5); c.quadraticCurveTo(p.x - 14, p.y + 5, p.x - 17, p.y - 2); c.fill();
      c.strokeStyle = dim(col, .4); c.lineWidth = .9; c.stroke();
      c.strokeStyle = "rgba(255,255,255,.2)"; c.beginPath(); c.moveTo(p.x - 8, p.y - 12); c.quadraticCurveTo(p.x, p.y - 8, p.x + 9, p.y - 11); c.stroke();
    } else if(it.kind === "couch"){
      const col = mix(BODY[hash(it.id) % BODY.length], "#8A8070", .25);
      for(const [lx, ly] of [[x + .16, y + 1.78], [x + 2.74, y + 1.78]]) prism(lx, ly, lx + .1, ly + .1, 0, 2, "#2A2420", {line:false});
      prism(x + .1, y + .25, x + 2.9, y + 1.9, 2, 13, dim(col, .1));
      inOrder([
        ...[0, 1, 2].map(i => { const a = x + .4 + i*.74; return [a + .36, y + 1.2, () => prism(a, y + .55, a + .72, y + 1.85, 13, 19, lit(col, .05))]; }),
        [x + 1.5, y + .38, () => prism(x + .1, y + .2, x + 2.9, y + .56, 13, 36, col)],
        [x + .26, y + 1.06, () => prism(x + .1, y + .2, x + .42, y + 1.92, 2, 25, dim(col, .05))],
        [x + 2.74, y + 1.06, () => prism(x + 2.58, y + .2, x + 2.9, y + 1.92, 2, 25, dim(col, .05))],
      ]);
    } else if(it.kind === "lamp"){
      // A floor lamp; its light is drawn with the room's lighting.
      const cx = x + .5, cy = y + .5, b = P(cx, cy, 0), s = P(cx, cy, 84);
      cylinder(cx, cy, 8, 0, 3, dim(metal, .1));
      prism(cx - .03, cy - .03, cx + .03, cy + .03, 3, 80, metal, {line:false});
      const shade = night() ? "#F9DDA2" : "#EFE3C8";
      c.fillStyle = shade; c.beginPath(); c.moveTo(s.x - 15, s.y + 8); c.lineTo(s.x - 9, s.y - 12); c.lineTo(s.x + 9, s.y - 12); c.lineTo(s.x + 15, s.y + 8); c.ellipse(s.x, s.y + 8, 15, 5, 0, 0, Math.PI); c.closePath(); c.fill();
      c.fillStyle = "rgba(120,80,30,.18)"; c.beginPath(); c.moveTo(s.x + 3, s.y - 12); c.lineTo(s.x + 9, s.y - 12); c.lineTo(s.x + 15, s.y + 8); c.lineTo(s.x + 6, s.y + 12); c.closePath(); c.fill();
      oval(s.x, s.y - 12, 9, 3, dim(shade, .2));
      if(night()) oval(s.x, s.y + 8, 13, 4, "#FFF4D6");
      void b;
    }
  }
  function drawYourDesk(room){
    const x0 = (W/2 - 220)/T, x1 = (W/2 + 220)/T, y0 = room.rows - 1.15, y1 = room.rows - .25, zt = 32;
    const wood = hexv("--rm-wood", "#C28C58"), wood2 = hexv("--rm-wood2", "#875A3B");
    prism(x0 + .12, y0 + .1, x1 - .12, y1 - .06, 0, zt - 4, wood2);
    // Its name on both long sides, so it reads from either way round.
    for(const [n, at] of [["y+", y1 - .06], ["y-", y0 + .1]]) face(n, at, () => {
      const [s0, s1] = span(n, x0 + .12, y0 + .1, x1 - .12, y1 - .06), l0 = s0*HW, l1 = s1*HW;
      for(let i = 1; i < 4; i++){ ctx.fillStyle = "rgba(0,0,0,.18)"; ctx.fillRect(l0 + (l1 - l0)*i/4, -zt + 6, 1.2, zt - 8); }
      ctx.fillStyle = lit(wood2, .55); ctx.font = font(19, 700); ctx.textAlign = "center";
      ctx.fillText("Your desk", (l0 + l1)/2, -8);
    });
    prism(x0, y0, x1, y1, zt - 4, zt, wood);
    // A laptop open toward your chair, a mug and some papers.
    const lx = (x0 + x1)/2 - 2.2;
    prism(lx, y0 + .25, lx + 1.1, y0 + .7, zt, zt + 1.5, "#C9CDD6", {line:false});
    prism(lx, y0 + .2, lx + 1.1, y0 + .26, zt + 1.5, zt + 18, "#C9CDD6", {line:"#8F949E"});
    faceY(y0 + .26, () => box((lx + .06)*HW, -(zt + 16.5), .98*HW, 13, 1, night() ? "#2F4C78" : "#3E5E8E"));
    cylinder(x1 - 2, y0 + .5, 4.5, zt, zt + 9, "#F3EEE2", "#5A3A22");
    const p = [P(x0 + 1.4, y0 + .25, zt + .5), P(x0 + 2.3, y0 + .2, zt + .5), P(x0 + 2.35, y0 + .75, zt + .5), P(x0 + 1.45, y0 + .8, zt + .5)];
    poly(p, "#F8F4EA", "rgba(0,0,0,.15)", .6);
    oval(P(x0 + 3.2, y0 + .5, zt).x, P(x0 + 3.2, y0 + .5, zt).y - 3, 6, 6, "#F5B700");
    ctx.fillStyle = "#FBF6EA"; hex(P(x0 + 3.2, y0 + .5, zt).x, P(x0 + 3.2, y0 + .5, zt).y - 3, 3.6); ctx.fill();
  }

  // ---------------------------------------------------------------- characters

  // Which way a character faces: walking, the way it's going; seated, toward the board; queued, toward you;
  // at an activity, toward the item it's using.
  // A direction in the room (tiles) as a sprite pose for this view: mirrored or not, and seen from behind or not.
  function toward(dx, dy){
    if(straight) return {face:dx < -.05 ? -1 : 1, back:dy < 0 && Math.abs(dy) >= Math.abs(dx)*.5};
    const [da, db] = turnDir(dx, dy); return {face:da - db < 0 ? -1 : 1, back:da + db < 0}; }
  function pose(a){
    const walking = a.path.length > 0, d = a.dest;
    if(walking || !d) return a.mx || a.my ? toward(a.mx, a.my) : {face:1, back:false};
    if(d.kind === "desk" && !d.standing) return toward(0, -1);
    if(d.kind === "queue") return toward(0, 1);
    if(d.kind === "helper" && !d.standing) return toward(0, 1);
    if(d.look === undefined){
      d.look = null;
      const want = d.kind, room = G.room;
      let best = null, bd = Infinity;
      for(const it of room.items){
        const cat = CAT[it.kind];
        if(!cat || cat.activity !== want || it.kind === "rug") continue;
        const ix = it.x + cat.w/2, iy = cat.zone === "wall" ? WR - .5 : it.y + cat.h/2, dd = Math.hypot(ix - a.x/T, iy - a.y/T);
        if(dd < bd){ bd = dd; best = {x:ix - a.x/T, y:iy - a.y/T}; }
      }
      if(best && bd < 4) d.look = best;
    }
    if(d.look) return toward(d.look.x, d.look.y);
    return a.mx || a.my ? {...toward(a.mx, a.my), back:false} : {face:1, back:false};
  }
  const stateColour = s => s.group === "needs" ? "#F5B700" : s.group === "working" ? hexv("--work", "#0B7480") : "#9AA3B5";
  function drawAgent(a, t, o){
    o = o || {};
    const c = ctx, s = a.s, walking = a.path.length > 0, ph = t*9 + a.seed, sc = s.isSub ? SUB : BIG;
    const seated = !!o.seated, stool = !!o.stool, nap = a.napping && !walking, pz = pose(a);
    const p = R(a.x, a.y), bob = walking ? Math.abs(Math.sin(ph))*2.5 : 0, lift = seated ? 17 - 11*sc : stool ? 11 - 11*sc : 0;
    const picked = sel === s.id, hovered = hover === s.id, accent = hexv("--accent", "#2F4DB0");
    c.save(); c.translate(p.x, p.y);
    if(!seated && !stool){
      oval(0, 0, 15*sc + 2, 7*sc + 1, css("--rm-shadow") || "rgba(0,0,0,.12)");
      oval(0, 0, 9*sc, 4*sc, css("--rm-shadow") || "rgba(0,0,0,.12)");
    }
    if((picked || hovered) && !seated){
      c.strokeStyle = accent; c.lineWidth = 2.4; c.globalAlpha = picked ? 1 : .75;
      c.beginPath(); c.ellipse(0, 0, 21*sc + 4, (21*sc + 4)/2, 0, 0, 7); c.stroke();
      if(picked){ c.fillStyle = alpha(accent, .15); c.fill(); }
      c.globalAlpha = 1;
    }
    c.translate(0, -bob - lift); c.scale(sc, sc);
    if(pz.face < 0) c.scale(-1, 1);
    robot(a, t, {walking, seated:seated || stool, nap, back:pz.back, halo:picked || hovered ? accent : null, ph});
    c.restore();
    const top = p.y - lift - bob - 92*sc;
    const r = {x:p.x - 22*sc, y:top, w:44*sc, h:p.y + 6 - top, id:s.id};
    heads.push(r); hitList.push(r);
  }
  // The robot itself, facing right, feet at (0, 0), 90 units tall.
  function robot(a, t, o){
    const c = ctx, s = a.s, col = a.color, ink = dim(col, .55), legC = mix(col, "#1B2030", .74), state = stateColour(s);
    const swing = o.walking ? Math.sin(o.ph)*4 : 0, back = o.back, sit = o.seated || o.nap;
    const sitting = o.seated && !o.walking, working = s.group === "working";
    if(o.halo){
      c.fillStyle = o.halo; hex(0, -58, 25.5); c.fill();
      c.beginPath(); c.roundRect(-16.5, -40.5, 33, 33, 10); c.fill();
      if(!sit) c.fillRect(-11, -14, 22, 16);
    }
    if(!sit){
      for(const [lx, sw] of [[-8, Math.max(0, swing)], [2, Math.max(0, -swing)]]){ box(lx, -13 + sw, 6, 13 - sw, 2.5, legC); box(lx - .8, -3.2, 7.6, 3.6, 1.6, dim(legC, .35)); }
    }
    const arm = (x0, y0, x1, y1, hand) => {
      c.lineCap = "round";
      c.strokeStyle = ink; c.lineWidth = 7.2; c.beginPath(); c.moveTo(x0, y0); c.lineTo(x1, y1); c.stroke();
      c.strokeStyle = col; c.lineWidth = 4.6; c.beginPath(); c.moveTo(x0, y0); c.lineTo(x1, y1); c.stroke();
      oval(x1, y1, 3.3, 3.3, hand || lit(col, .2));
    };
    const handUp = s.group === "needs" && !o.walking && !back;
    const typing = sitting && working && back;
    const jig = typing && !calm.matches ? Math.sin(t*14 + a.seed)*1.6 : 0;
    if(typing){ arm(-12, -31, -15, -24 + jig); arm(12, -31, 17, -33 - jig); }
    else { arm(-12, -31, -17, -18 + swing); if(!handUp) arm(12, -31, 17, -18 - swing); }
    // body
    const bg = c.createLinearGradient(-13, 0, 13, 0); bg.addColorStop(0, lit(col, .18)); bg.addColorStop(1, dim(col, .18));
    c.fillStyle = bg; c.beginPath(); c.roundRect(-13, -37, 26, 26, 8); c.fill(); c.strokeStyle = ink; c.lineWidth = 1.4; c.stroke();
    if(!back){
      box(-8, -31, 16, 11, 3.5, lit(col, .62));
      oval(4, -25.5, 2, 2, state);
      c.fillStyle = dim(col, .1); c.fillRect(-5.5, -28, 6, 1.4); c.fillRect(-5.5, -24.5, 4, 1.4);
      if(s.provider === "google" && !s.isSub) ["#4285F4", "#EA4335", "#FBBC05", "#34A853"].forEach((dc, i) => oval(-4.5 + i*3, -21.5, 1.2, 1.2, dc));
      if(a.dest?.kind === "read" && !o.walking){ box(-12, -31, 24, 14, 2, "#F7EFD9"); c.fillStyle = col; c.fillRect(-1, -31, 2, 14); c.fillStyle = "rgba(0,0,0,.25)"; for(const lx of [-9, 3]) for(let i = 0; i < 3; i++) c.fillRect(lx, -27 + i*3, 6, .8); }
    } else {
      c.fillStyle = dim(col, .28); for(const vy of [-31, -27, -23]) c.fillRect(-6, vy, 12, 1.6);
    }
    if(handUp){ const w = calm.matches ? 0 : Math.sin(t*6 + a.seed)*5; arm(12, -31, 21 + w, -70, "#F7EFD9"); }
    box(-4, -43, 8, 7, 2, legC);
    // head
    c.save();
    if(o.nap){ c.translate(0, -40); c.rotate(.3); c.translate(0, 40); }
    c.fillStyle = dim(col, .4); hex(-3.2, -56.5, 21); c.fill();
    const hg = c.createLinearGradient(0, -79, 0, -37); hg.addColorStop(0, lit(col, .24)); hg.addColorStop(1, dim(col, .1));
    c.fillStyle = hg; hex(0, -58, 21); c.fill(); c.strokeStyle = ink; c.lineWidth = 1.6; c.stroke();
    c.strokeStyle = lit(col, .5); c.lineWidth = 1.4; c.lineCap = "round";
    c.beginPath(); c.moveTo(-16, -66.5); c.lineTo(0, -76); c.lineTo(9, -70.7); c.stroke();
    const blink = o.nap || (!calm.matches && (t + a.seed) % 4.3 < .13), look = calm.matches ? 0 : o.walking ? 1.5 : Math.sin(t*.7 + a.seed)*1.2;
    if(!back){
      const pg = c.createLinearGradient(0, -74, 0, -42); pg.addColorStop(0, "#FFFBF0"); pg.addColorStop(1, "#EADFC6");
      c.fillStyle = pg; hex(1.5, -58, 16); c.fill(); c.strokeStyle = "rgba(60,40,20,.2)"; c.lineWidth = 1; c.stroke();
      c.fillStyle = "#1C2130"; c.strokeStyle = "#1C2130"; c.lineWidth = 2;
      for(const ex of [-4.5, 7.5]){
        if(blink){ c.beginPath(); c.arc(ex + look, -59, 2.6, .15, Math.PI - .15); c.stroke(); }
        else { oval(ex + look, -59, 2.6, 2.9, "#1C2130"); oval(ex + look - .8, -60, .9, .9, "#FFFFFF"); }
      }
      oval(-8.5 + look, -53, 2.6, 1.5, "rgba(232,110,120,.3)"); oval(11.5 + look, -53, 2.6, 1.5, "rgba(232,110,120,.3)");
      c.strokeStyle = "#1C2130"; c.lineWidth = 1.8; c.beginPath();
      if(s.quiet){ c.moveTo(-1.5 + look, -52); c.lineTo(4.5 + look, -52); c.stroke(); }
      else if(s.group === "needs" && !o.walking){ oval(1.5 + look, -52, 2.2, 2.6, "#1C2130"); }
      else { c.arc(1.5 + look, -54.5, 3.6, .25, Math.PI - .25); c.stroke(); }
      if(a.hat === 2){ c.lineWidth = 1.3; for(const ex of [-4.5, 7.5]){ c.beginPath(); c.arc(ex + look, -59, 5, 0, 7); c.stroke(); } c.beginPath(); c.moveTo(.5 + look, -59); c.lineTo(2.5 + look, -59); c.stroke(); }
    } else {
      box(-8, -65, 16, 13, 3, dim(col, .16));
      oval(-5, -62, 1.1, 1.1, lit(col, .3)); oval(5, -62, 1.1, 1.1, lit(col, .3)); oval(-5, -55, 1.1, 1.1, lit(col, .3)); oval(5, -55, 1.1, 1.1, lit(col, .3));
    }
    if(a.hat === 1){ c.fillStyle = dim(col, .12); c.beginPath(); c.moveTo(-15, -70); c.lineTo(0, -82); c.lineTo(15, -70); c.closePath(); c.fill(); c.strokeStyle = ink; c.lineWidth = 1.2; c.stroke(); }
    c.strokeStyle = ink; c.lineWidth = 2.2; c.beginPath(); c.moveTo(0, -78); c.lineTo(0, -87); c.stroke();
    if(s.group !== "idle"){ const g = c.createRadialGradient(0, -89, 0, 0, -89, 9); g.addColorStop(0, alpha(rgbHex(state), .6)); g.addColorStop(1, alpha(rgbHex(state), 0)); c.fillStyle = g; c.beginPath(); c.arc(0, -89, 9, 0, 7); c.fill(); }
    oval(0, -89, 3.5, 3.5, state); oval(-1, -90, 1.1, 1.1, "rgba(255,255,255,.8)");
    c.restore();
  }
  const rgbHex = v => /^#[0-9a-f]{6}$/i.test(v) ? v : "#0B7480";

  // ---------------------------------------------------------------- depth order

  // A thing to draw: its floor box in tiles (x0..x1, y0..y1), how far it reaches on screen, and how to draw it.
  // The box is kept in the turned frame, so order() works the same in every view.
  function thing(x0, y0, x1, y1, h, f, pad){
    if(straight){ const top = P(x0, y0, h), bot = P(x0, y1, 0); return {x0, y0, x1, y1, h, sx0:P(x0, 0).x - (pad || 0), sx1:P(x1, 0).x + (pad || 0), sy0:top.y - 6, sy1:bot.y + 6, f}; }
    const r = turnBox(x0, y0, x1, y1), a = Q(r.a0, r.b1), b = Q(r.a1, r.b0), top = Q(r.a0, r.b0, h), bot = Q(r.a1, r.b1);
    return {x0:r.a0, y0:r.b0, x1:r.a1, y1:r.b1, sx0:a.x - (pad || 0), sx1:b.x + (pad || 0), sy0:top.y - 6, sy1:bot.y + 6, f};
  }
  // Back to front. Where two things overlap on screen, the one whose floor box is wholly behind the other's on
  // either axis is drawn first; boxes that overlap on the floor go by the middle of their boxes.
  function order(list){
    // Straight on, only y says what's in front (then height); in the angled view either axis can.
    const n = list.length, before = Array.from({length:n}, () => []);
    const mid = straight ? d => d.y0 + d.y1 + (d.h || 0)*1e-4 : d => d.x0 + d.x1 + d.y0 + d.y1;
    for(let i = 0; i < n; i++) for(let j = i + 1; j < n; j++){
      const A = list[i], B = list[j];
      if(A.sx1 <= B.sx0 || B.sx1 <= A.sx0 || A.sy1 <= B.sy0 || B.sy1 <= A.sy0) continue;
      const ab = (!straight && A.x1 <= B.x0 + 1e-6) || A.y1 <= B.y0 + 1e-6, ba = (!straight && B.x1 <= A.x0 + 1e-6) || B.y1 <= A.y0 + 1e-6;
      const aFirst = ab !== ba ? ab : mid(A) <= mid(B);
      if(aFirst) before[j].push(i); else before[i].push(j);
    }
    const out = [], state = new Uint8Array(n);
    const visit = i => { if(state[i]) return; state[i] = 1; for(const j of before[i]) visit(j); out.push(list[i]); };
    [...list.keys()].sort((i, j) => mid(list[i]) - mid(list[j])).forEach(visit);
    return out;
  }

  // ---------------------------------------------------------------- lighting

  // Evening: the whole room dims, then lamps, working desks and the board's light add warm pools.
  function roomOutline(room){
    if(straight){ trace([P(-SIDE, WR - THICK, WALLH), P(room.cols + SIDE, WR - THICK, WALLH), P(room.cols + SIDE, room.rows, -SLAB), P(-SIDE, room.rows, -SLAB)]); return; }
    const A = rot % 2 ? room.rows - WR : room.cols, B = rot % 2 ? room.cols : room.rows - WR;
    trace([Q(-THICK, B, WALLH), Q(-THICK, -THICK, WALLH), Q(A, -THICK, WALLH), Q(A, 0, -SLAB), Q(A, B, -SLAB), Q(0, B, -SLAB), Q(-THICK, B, -SLAB)]);
  }
  function lighting(room, owners, t){
    const c = ctx, amb = css("--rm-ambient"), rgb = glow(), ga = glowA();
    if(amb && amb !== "none"){ c.save(); c.globalCompositeOperation = "multiply"; c.fillStyle = amb; roomOutline(room); c.fill(); c.restore(); }
    c.save(); c.globalCompositeOperation = "screen";
    const pool = (x, y, r, a) => onFloor(() => {
      const g = c.createRadialGradient(x, y, 0, x, y, r);
      g.addColorStop(0, `rgba(${rgb},${a})`); g.addColorStop(.45, `rgba(${rgb},${a*.45})`); g.addColorStop(1, `rgba(${rgb},0)`);
      c.fillStyle = g; c.beginPath(); c.arc(x, y, r, 0, 7); c.fill();
    });
    const spot = (p, r, a, colour) => { const g = c.createRadialGradient(p.x, p.y, 0, p.x, p.y, r); g.addColorStop(0, `rgba(${colour},${a})`); g.addColorStop(1, `rgba(${colour},0)`); c.fillStyle = g; c.beginPath(); c.arc(p.x, p.y, r, 0, 7); c.fill(); };
    G.slots.forEach((d, i) => {
      const o = owners.get(i);
      if(o?.s.group !== "working") return;
      const flicker = calm.matches ? 1 : .94 + .06*Math.sin(t*3 + i);
      pool((d.x + 1.8)*T, (d.y + 1)*T, 2.1*T, .55*ga*flicker);
      spot(P(d.x + 2.3, d.y + .5, 27), 26, .5*ga, rgb);
      spot(P(d.x + 1.5, d.y + .42, 45), 22, .35*ga, "120,220,230");
    });
    for(const it of room.items) if(it.kind === "lamp"){
      const cx = (it.x + .5)*T, cy = (it.y + .5)*T;
      pool(cx, cy, 3*T, (night() ? .75 : .3)*ga);
      spot(P(it.x + .5, it.y + .5, 90), 34, .6*ga, rgb);
    }
    for(const w of farWalls(room)) if(!w.back) for(const s of sconces(w)){
      const [wx, wy2] = wallPoint(w, s), [nx, ny] = NORMAL[w.n], p = P(wx, wy2, WALLH*.62);
      c.save(); c.translate(p.x, p.y); c.transform(1, w.side === "b" ? .5 : -.5, 0, 1, 0, 0); c.scale(1, 1.6); spot({x:0, y:0}, 64, (night() ? .5 : .12)*ga, rgb); c.restore();
      spot(P(wx + nx*.05, wy2 + ny*.05, WALLH*.62 - 4), 12, (night() ? .8 : .2)*ga, "255,240,210");
      pool((wx + nx*.6)*T, (wy2 + ny*.6)*T, 1.6*T, (night() ? .35 : .1)*ga);
    }
    for(const it of room.items) if(it.kind === "board" && night() && backShown()){
      const r = boardRect(it), p = {x:r.x + r.w/2, y:r.y + r.h*.35};
      c.save(); c.translate(p.x, p.y); c.scale(1, .45); spot({x:0, y:0}, r.w*.55, .22*ga, rgb); c.restore();
    }
    const door = room.items.find(it => it.kind === "door");
    if(door && [...agents.values()].some(a => Math.hypot(a.x - G.door.x, a.y - G.door.y) < 80)) pool((door.x + 1.5)*T, (WR + .6)*T, 1.6*T, .5*ga);
    c.restore();
  }

  // ---------------------------------------------------------------- text

  // The spot already says what kind of work it is, so the bubble only says what the work is.
  function taskOf(text){
    const rest = String(text || "").replace(/^(Running|Reading|Editing|Writing|Searching|Fetching|Starting|Using|Sending|Opening|Taking|Waiting on|Run|Read|Write|Search|Call)\s+/i, "");
    return rest.charAt(0).toUpperCase() + rest.slice(1);
  }
  function textOf(a){
    const s = a.s;
    if(s.isSub) return "";
    const n = s.questions?.length || 0;
    const ask = s.reason === "questions" && n ? `${n} question${n === 1 ? "" : "s"}` : ASK[s.reason] || "Waiting";
    if(s.group === "needs") return ask + ", " + shortAge(Date.now()/1000 - (s.statusSince || s.lastTs));
    if(s.group === "working") return s.quiet ? "Gone quiet" : taskOf(s.headline) || LABEL[s.doing] || "Working";
    return "";
  }
  function shortAge(sec){ return sec < 3600 ? Math.max(1, Math.round(sec/60)) + "m" : sec < 86400 ? Math.round(sec/3600) + "h" : Math.round(sec/86400) + "d"; }
  function fit(text, max){
    let out = text;
    while(ctx.measureText(out).width > max && out.length > 4) out = out.slice(0, -2) + "…";
    return out;
  }
  function lines(text, max){
    const out = [];
    let cur = "";
    for(const word of text.split(/\s+/)){
      const next = cur ? cur + " " + word : word;
      if(!cur || ctx.measureText(next).width <= max) cur = next;
      else { out.push(cur); cur = word; }
    }
    out.push(cur);
    if(out.length > 2) out.splice(1, out.length, out[1] + "…");
    return out.map(l => fit(l, max));
  }
  // Text placement, one pass per frame in priority order: needs-you callouts, the selected or highlighted
  // session's bubble, then desk name plates where they fit. Each piece goes to the nearest free spot within 60
  // units of where it wants to be, inside the drawing and off the chalkboard; a piece with no free spot is left out.
  const OFFSETS = (() => { const out = []; for(let dy = -60; dy <= 60; dy += 6) for(let dx = -60; dx <= 60; dx += 6){ const d = Math.hypot(dx, dy); if(d <= 60) out.push({dx, dy, d}); } return out.sort((p, q) => p.d - q.d); })();
  const hits = (r, list, pad) => list.some(p => r.x < p.x + p.w + pad && r.x + r.w + pad > p.x && r.y < p.y + p.h + pad && r.y + r.h + pad > p.y);
  function spot(x, y, w, h, up){
    let best = null;
    const v = shown();
    for(const o of OFFSETS){
      if(best && o.d > best.d) break;
      const r = {x:x + o.dx, y:y + o.dy, w, h};
      if(r.x < v.x0 + 2 || r.y < v.y0 + 2 || r.x + w > v.x1 - 2 || r.y + h > v.y1 - 2 || hits(r, keepOut, 2) || hits(r, placed, 3)) continue;
      // Among spots as near as each other, bubbles prefer to move up and tags down.
      if(!best || (up ? o.dy < best.dy : o.dy > best.dy)) best = {...r, d:o.d, dy:o.dy};
    }
    if(!best) return null;
    const r = {x:best.x, y:best.y, w, h};
    placed.push(r);
    return r;
  }
  // Text grows as the room shrinks, so it stays readable in a small window.
  // Text is 11 to 16 px on screen whatever the zoom: base sizes are for 12 px, scaled with the room between those.
  const textScale = () => Math.min(16, Math.max(11, 12*k))/(12*k);
  // The part of the drawing in view, in drawing units.
  const shown = () => ({x0:-ox/k, y0:-oy/k, x1:(CW - ox)/k, y1:(CH - oy)/k});
  const fontOf = ts => (px, weight) => font(Math.round(px*ts), weight || 600);
  const headOf = a => { const p = R(a.x, a.y), sc = a.s.isSub ? SUB : BIG, lift = !a.path.length && a.dest?.kind === "desk" && !a.dest.standing ? 17 - 11*sc : 0; return {x:p.x, y:p.y - lift - 92*sc}; };
  function tail(at, w, h, to, fill, edge){
    const c = ctx, bx = Math.max(at.x + 10, Math.min(at.x + w - 10, to.x));
    if(to.y < at.y + h + 2) return;
    c.fillStyle = fill; c.beginPath(); c.moveTo(bx - 5, at.y + h - 1); c.lineTo(bx + 5, at.y + h - 1); c.lineTo(to.x, Math.min(to.y - 2, at.y + h + 9)); c.closePath(); c.fill();
    if(edge){ c.strokeStyle = edge; c.lineWidth = 1; c.beginPath(); c.moveTo(bx - 5, at.y + h); c.lineTo(to.x, Math.min(to.y - 2, at.y + h + 9)); c.lineTo(bx + 5, at.y + h); c.stroke(); }
  }
  // A session waiting on you: its name and what it's waiting for, in honey.
  function needBubble(a){
    const c = ctx, ts = textScale(), F = fontOf(ts), ask = textOf(a);
    if(!ask) return;
    c.font = F(12.5, 700); const name = fit(a.s.name || "", 170*ts), nw = c.measureText(name).width;
    c.font = F(12, 500); const aw = c.measureText(ask).width;
    const w = Math.max(nw, aw) + 18, h = 34*ts, head = headOf(a);
    const at = spot(Math.max(6, Math.min(SW - w - 6, head.x - w/2)), head.y - 10 - h, w, h, true);
    if(!at) return;
    c.shadowColor = "rgba(0,0,0,.18)"; c.shadowBlur = 6; c.shadowOffsetY = 2;
    box(at.x, at.y, w, h, 8, "#F5B700");
    c.shadowColor = "transparent"; c.shadowBlur = 0; c.shadowOffsetY = 0;
    tail(at, w, h, head, "#F5B700");
    c.textAlign = "left"; c.fillStyle = "#2A1F00";
    c.font = F(12.5, 700); c.fillText(name, at.x + 9, at.y + 15*ts);
    c.font = F(12, 500); c.fillStyle = "#4F3B00"; c.fillText(ask, at.x + 9, at.y + 29*ts);
  }
  // The selected or highlighted session: its name and what it's doing.
  function bubble(a){
    const c = ctx, ts = textScale(), F = fontOf(ts), s = a.s, lh = 15*ts;
    const what = s.isSub ? (s.headline || "Subagent") : textOf(a) || (s.group === "idle" ? "Idle" : "");
    c.font = F(12.5, 700); const name = fit(s.name || "", 170*ts);
    c.font = F(12, 500); const rows = what ? lines(what, 170*ts) : [];
    c.font = F(12.5, 700); let w = c.measureText(name).width;
    c.font = F(12, 500); for(const l of rows) w = Math.max(w, c.measureText(l).width);
    w += 20; const h = (rows.length + 1)*lh + 10, head = headOf(a);
    const at = spot(Math.max(6, Math.min(SW - w - 6, head.x - w/2)), head.y - 12 - h, w, h, true);
    if(!at) return;
    const panel = hexv("--rm-panel", "#FFFDF8"), line = css("--line") || "#D2D7E2";
    c.shadowColor = "rgba(0,0,0,.2)"; c.shadowBlur = 8; c.shadowOffsetY = 2;
    box(at.x, at.y, w, h, 9, panel);
    c.shadowColor = "transparent"; c.shadowBlur = 0; c.shadowOffsetY = 0;
    c.strokeStyle = line; c.lineWidth = 1; c.beginPath(); c.roundRect(at.x + .5, at.y + .5, w - 1, h - 1, 9); c.stroke();
    tail(at, w, h, head, panel, line);
    box(at.x + 8, at.y + 7 + lh*.18, 3, lh*.62, 1.5, a.color);
    c.textAlign = "left"; c.fillStyle = css("--ink");
    c.font = F(12.5, 700); c.fillText(name, at.x + 15, at.y + 5 + lh*.8);
    c.font = F(12, 500); c.fillStyle = css("--ink2");
    rows.forEach((l, i) => c.fillText(l, at.x + 10, at.y + 5 + lh*(i + 1.8)));
  }
  // A desk's name plate, on the front of the desk, drawn only where it covers nothing.
  function plate(slot, owner){
    const c = ctx, ts = textScale(), s = owner.s;
    c.font = font(Math.round(10.5*ts), 600);
    const extra = (s.helpers?.length || 0) > 6 ? ` +${s.helpers.length - 6}` : "";
    const name = fit(s.name || "", 84*ts - (extra ? c.measureText(extra).width : 0)) + extra;
    // On the desk top's front corner in this view, a little way in.
    const corners = [[slot.x + .1, slot.y + .06], [slot.x + 2.9, slot.y + .06], [slot.x + .1, slot.y + 1.06], [slot.x + 2.9, slot.y + 1.06]];
    const [fx, fy] = corners.reduce((m, q) => depth(q[0], q[1]) > depth(m[0], m[1]) ? q : m);
    // Straight on, the sitter covers the desk's front, so the plate goes on the floor in front of the chair.
    const w = c.measureText(name).width + 14, h = 15*ts, at = straight ? P(slot.x + 1.5, slot.y + 2.05, -h/2 - 3) : P(fx + (slot.x + 1.5 - fx)*.3, fy + (slot.y + .56 - fy)*.3, 10);
    if(w > 4*HW) return;   // zoomed out so far that the plate would be wider than the desk
    const r = {x:at.x - w/2, y:at.y - h/2, w, h}, v = shown();
    if(r.x < v.x0 + 2 || r.x + w > v.x1 - 2 || r.y < v.y0 + 2 || r.y + h > v.y1 - 2 || hits(r, placed, 2) || hits(r, keepOut, 2) || hits(r, heads.filter(q => q.id !== s.id), 0)) return;
    placed.push(r);
    box(r.x, r.y, w, h, 3, hexv("--rm-plate", "#F3E6C4"));
    box(r.x, r.y, 3.5, h, 1.5, owner.color);
    c.fillStyle = hexv("--rm-plate-ink", "#3A2A14"); c.textAlign = "center"; c.fillText(name, r.x + w/2 + 1.5, r.y + h/2 + 3.8*ts);
    hitList.push({...r, id:s.id});
  }
  function drawZ(a, t){
    if(!a.napping || a.path.length) return;
    const head = headOf(a), n = calm.matches ? 2 : 1 + Math.floor(t*1.2 + a.seed) % 3;
    ctx.fillStyle = css("--ink2"); ctx.globalAlpha = .85; ctx.font = fontOf(textScale())(13, 700); ctx.textAlign = "left";
    for(let i = 0; i < n; i++) ctx.fillText("z", head.x + 14 + i*7, head.y + 6 - i*8);
    ctx.globalAlpha = 1;
  }
  function message(text, p){
    const c = ctx, ts = textScale();
    c.font = font(Math.round(14*ts), 600);
    const w = c.measureText(text).width + 24, h = 26*ts, r = {x:p.x - w/2, y:p.y - h/2, w, h};
    box(r.x, r.y, w, h, h/2, alpha(hexv("--rm-panel", "#FFFDF8"), .88));
    c.fillStyle = css("--ink2"); c.textAlign = "center"; c.fillText(text, p.x, p.y + 5*ts);
    keepOut.push(r);
  }

  // ---------------------------------------------------------------- frames

  function seatedAt(a){ return !a.path.length && a.dest?.kind === "desk" && !a.dest.standing; }
  // A running subagent has a stool beside its session's desk, and sits on it while it is at home.
  const onStool = a => a.s.isSub && !a.path.length && a.dest?.kind === "helper" && !a.dest.standing;
  function drawLive(t){
    const room = G.room, n = board?.counts || {};
    heads = []; hitList = []; placed = []; editHits = null;
    shell(room, G.slots, null);
    for(const it of room.items) if(CAT[it.kind]?.zone === "wall") drawWallItem(it, t, 2);
    const owners = new Map([...agents.values()].filter(a => !a.s.isSub && !a.leaving && deskOf(a) !== undefined).map(a => [deskOf(a), a]));
    const list = [], drawn = new Set();
    G.slots.forEach((d, i) => {
      const o = owners.get(i), sitter = o && seatedAt(o) ? o : null;
      if(sitter) drawn.add(sitter);
      list.push(thing(d.x + .06, d.y + .04, d.x + 2.94, d.y + 1.08, TALL.desk, () => drawDesk(d, o, t)));
      list.push(thing(d.x + 1.18, d.y + 1.14, d.x + 1.82, d.y + 1.8, 40 + (sitter ? 90 : 0), () => drawChair(d, sitter, t), sitter ? 20 : 0));
      if(o){ const pts = hull(d.x, d.y, d.x + 3, d.y + 1.06, 62), xs = pts.map(p => p.x), ys = pts.map(p => p.y); hitList.push({x:Math.min(...xs), y:Math.min(...ys), w:Math.max(...xs) - Math.min(...xs), h:Math.max(...ys) - Math.min(...ys), id:o.s.id}); }
    });
    for(const it of room.items){
      const cat = CAT[it.kind];
      if(!cat || cat.zone !== "floor" || it.kind === "rug" || it.kind === "desk") continue;
      list.push(thing(it.x + .05, it.y + .05, it.x + cat.w - .05, it.y + cat.h - .05, TALL[it.kind], () => drawItem(it, t)));
    }
    for(const a of agents.values()){
      if(!a.s.isSub || a.leaving) continue;
      const h = seatOf(a);
      if(h.kind !== "helper" || h.standing) continue;
      const on = onStool(a);
      if(on) drawn.add(a);
      list.push(thing(h.x/T - .2, h.y/T - .2, h.x/T + .2, h.y/T + .2, on ? 70 : 14, () => { drawStool(h.x, h.y); if(on) drawAgent(a, t, {stool:true}); }, on ? 16 : 0));
    }
    const x0 = (W/2 - 220)/T, x1 = (W/2 + 220)/T;
    list.push(thing(x0, room.rows - 1.15, x1, room.rows - .25, 60, () => drawYourDesk(room)));
    for(const a of agents.values()) if(!drawn.has(a)) list.push(thing(a.x/T - .2, a.y/T - .2, a.x/T + .2, a.y/T + .2, 100, () => drawAgent(a, t), 22));
    order(list).forEach(d => d.f());
    lighting(room, owners, t);
    // Text never covers the chalkboard, the door's count, your desk's label or the mat's.
    doorCount(room);
    keepOut = backShown() ? room.items.filter(it => it.kind === "board").map(boardRect) : [];
    if(doorLabel) keepOut.push(doorLabel);
    if(matLabel) keepOut.push(matLabel);
    const ydp = [-1.6, 1.6].flatMap(dx => [room.rows - .3, room.rows - 1.05].flatMap(y => [0, 26].map(z => P((x0 + x1)/2 + dx, y, z))));
    const ydx = ydp.map(p => p.x), ydy = ydp.map(p => p.y);
    keepOut.push({x:Math.min(...ydx), y:Math.min(...ydy), w:Math.max(...ydx) - Math.min(...ydx), h:Math.max(...ydy) - Math.min(...ydy)});
    if(!n.needs){ const geo = frontOf(room); message("Nobody is waiting on you right now.", R(Math.min(W - 9*T, W/2 + 9*T), (geo.matTop + geo.matBottom)/2)); }
    if(board?.ready && !agents.size && G.slots[0]){ const d = G.slots[0]; message("No sessions are open, so the room is empty.", P(d.x + 1.5, d.y - 1.2, 0)); }
    const live = [...agents.values()].filter(a => !a.leaving);
    live.forEach(a => drawZ(a, t));   // under the bubbles
    live.filter(a => a.s.group === "needs" && !a.s.isSub).sort((p, q) => q.y - p.y || p.seed - q.seed).forEach(needBubble);
    for(const id of [sel, hover]){
      if(!id || (id === hover && id === pointerOn)) continue;
      const a = agents.get(id);
      if(a && a.s.group !== "needs") bubble(a);
    }
    // Sessions named elsewhere (their callout or bubble) get no plate.
    G.slots.forEach((d, i) => { const o = owners.get(i); if(o && o.s.group !== "needs" && o.s.id !== sel && o.s.id !== hover) plate(d, o); });
  }
  // Edit mode: the draft with a tile grid, the fixed front shaded, characters frozen and faded, the selected item
  // outlined, and the item being dragged shown where it would go (red, with the reason, if it can't go there).
  function drawEdit(t){
    const room = draft, c = ctx, g = view.ghost, frontTop = room.rows - RoomModel.FRONT_ROWS;
    heads = []; hitList = []; placed = [];
    const visible = room.items.filter(it => CAT[it.kind] && !(g && g.id === it.id));
    const desks = visible.filter(it => it.kind === "desk").map(d => ({x:d.x, y:d.y, extra:false}));
    shell(room, desks, g?.id || null);
    for(const it of visible) if(CAT[it.kind].zone === "wall") drawWallItem(it, t, 2);
    // The grid over everywhere things can go; the front is fixed.
    const ink3 = css("--ink3") || "#626C80";
    c.save(); c.lineWidth = 1.4; c.strokeStyle = "rgba(255,250,240,.6)";
    c.beginPath();
    for(let x = 0; x <= room.cols; x++){ const a = P(x, WR), b = P(x, frontTop); c.moveTo(a.x, a.y); c.lineTo(b.x, b.y); }
    for(let y = WR; y <= frontTop; y++){ const a = P(0, y), b = P(room.cols, y); c.moveTo(a.x, a.y); c.lineTo(b.x, b.y); }
    c.stroke();
    // The back wall's grid, when the back wall is in view (wall items can only be placed there).
    if(backShown()){
      c.globalAlpha = .55; c.strokeStyle = night() ? "#F4EAD8" : ink3; c.lineWidth = 1.3;
      c.beginPath();
      for(let x = 0; x <= room.cols; x++){ const a = P(x, WR, 0), b = P(x, WR, WALLH); c.moveTo(a.x, a.y); c.lineTo(b.x, b.y); }
      for(let y = 0; y <= WR; y++){ const a = P(0, WR, (WR - y)*WZ), b = P(room.cols, WR, (WR - y)*WZ); c.moveTo(a.x, a.y); c.lineTo(b.x, b.y); }
      c.stroke();
    }
    c.restore();
    poly([P(0, frontTop), P(room.cols, frontTop), P(room.cols, room.rows), P(0, room.rows)], "rgba(110,110,140,.2)");
    floorText("Fixed: the queue and your desk", 60, W - 60, frontTop*T + 30, font(22, 700), css("--ink2"), "end");
    // Furniture and the faded characters, back to front, and what each item covers for picking.
    const list = [];
    editHits = [];
    if(backShown()) for(const it of visible) if(CAT[it.kind].zone === "wall") editHits.push({id:it.id, poly:wallQuad(it)});
    for(const it of visible) if(it.kind === "rug") editHits.push({id:it.id, poly:floorQuad(it)});
    for(const it of visible){
      const cat = CAT[it.kind];
      if(cat.zone !== "floor" || it.kind === "rug") continue;
      const d = thing(it.x + .05, it.y + .05, it.x + cat.w - .05, it.y + cat.h - .05, TALL[it.kind], () => { drawItem(it, t); editHits.push({id:it.id, poly:hull(it.x, it.y, it.x + cat.w, it.y + cat.h, TALL[it.kind])}); });
      list.push(d);
    }
    const x0 = (W/2 - 220)/T, x1 = (W/2 + 220)/T;
    list.push(thing(x0, room.rows - 1.15, x1, room.rows - .25, 60, () => drawYourDesk(room)));
    for(const a of agents.values()) list.push(thing(a.x/T - .2, a.y/T - .2, a.x/T + .2, a.y/T + .2, 100, () => { c.globalAlpha = .3; drawAgent(a, t); c.globalAlpha = 1; }, 22));
    order(list).forEach(d => d.f());
    const outline = (it, colour, fill) => {
      const pts = CAT[it.kind].zone === "wall" ? wallQuad(it) : floorQuad(it);
      if(fill) poly(pts, fill);
      c.lineJoin = "round"; poly(pts, null, colour, 3);
      if(CAT[it.kind].zone === "floor" && TALL[it.kind]){ c.globalAlpha = .6; const cat = CAT[it.kind]; poly(hull(it.x, it.y, it.x + cat.w, it.y + cat.h, TALL[it.kind]), null, colour, 1.5); c.globalAlpha = 1; }
      return pts;
    };
    doorCount(room);
    const chosen = room.items.find(it => it.id === view.selected);
    if(chosen && !(g && g.id === chosen.id) && (CAT[chosen.kind].zone === "floor" || backShown())) outline(chosen, hexv("--accent", "#2F4DB0"));
    if(g){
      const it = {id:g.id || "new", kind:g.kind, x:g.x, y:g.y};
      c.globalAlpha = .78;
      if(CAT[g.kind].zone === "wall" && g.y < WR) drawWallItem(it, t, 3);
      else if(CAT[g.kind].zone === "floor" && g.y >= WR){ if(g.kind === "rug") drawRug(it); else drawItem(it, t); }
      c.globalAlpha = 1;
      const pts = outline(it, g.bad ? "#D23B3B" : hexv("--accent", "#2F4DB0"), g.bad ? "rgba(210,59,59,.3)" : "rgba(80,140,255,.14)");
      if(g.bad){
        c.font = font(Math.round(13*textScale()), 600); c.textAlign = "center";
        const text = fit(g.bad.charAt(0).toUpperCase() + g.bad.slice(1), 380), w = c.measureText(text).width + 18, h = 24*textScale();
        const bottom = Math.max(...pts.map(p => p.y)), top = Math.min(...pts.map(p => p.y)), cx = pts.reduce((s, p) => s + p.x, 0)/pts.length;
        const x = Math.max(4, Math.min(SW - w - 4, cx - w/2)), y = bottom + 8 + h < SH ? bottom + 8 : top - h - 8;
        box(x, y, w, h, 6, "#D23B3B"); c.fillStyle = "#FFFFFF"; c.fillText(text, x + w/2, y + h/2 + 4.5*textScale());
      }
    }
  }
  // Where an item is on screen: a wall item's rectangle on the back wall, a floor item's footprint.
  const wallQuad = it => { const cat = CAT[it.kind], zt = (WR - it.y)*WZ, zb = (WR - it.y - cat.h)*WZ; return [P(it.x, WR, zt), P(it.x + cat.w, WR, zt), P(it.x + cat.w, WR, zb), P(it.x, WR, zb)]; };
  const floorQuad = it => { const cat = CAT[it.kind]; return [P(it.x, it.y), P(it.x + cat.w, it.y), P(it.x + cat.w, it.y + cat.h), P(it.x, it.y + cat.h)]; };
  function frame(ms){
    if(!active) return;
    requestAnimationFrame(frame);
    if(document.hidden || ms - last < (calm.matches ? 250 : turning ? 16 : 30)) return;
    const dt = Math.min(.25, (ms - last)/1000); last = ms;
    const now = ms/1000, t = calm.matches ? 0 : now;
    if(!G) build();
    applyView();
    if(draft){ clear(); drawEdit(t); turnEffect(); return; }
    const queue = [...agents.values()].filter(a => a.s.group === "needs" && !a.leaving).sort((x,y) => (x.s.statusSince||0) - (y.s.statusSince||0)).map(a => a.s.id);
    for(const a of [...agents.values()]){
      plan(a, now, queue);
      const speed = a.s.isSub ? 165 : a.s.group === "idle" ? 85 : 135;
      let left = speed * dt;
      while(left > 0 && a.path.length){
        const p = a.path[0], dx = p.x-a.x, dy = p.y-a.y, dist = Math.hypot(dx,dy);
        // The way it's walking, in the room, for its pose in whichever view.
        if(dist > 1){ a.mx = dx/dist; a.my = dy/dist; }
        if(dist <= left){ a.x = p.x; a.y = p.y; a.path.shift(); left -= dist; } else { a.x += dx/dist*left; a.y += dy/dist*left; left = 0; }
      }
      if(a.leaving && !a.path.length && a.dest?.kind === "door") agents.delete(a.s.id);
    }
    clear();
    drawLive(t);
    turnEffect();
  }
  function clear(){ ctx.setTransform(1, 0, 0, 1, 0, 0); ctx.clearRect(0, 0, cv.width, cv.height); begin(); }
  function size(){
    if(!G) build();
    dims();
    const area = cv.parentElement.getBoundingClientRect();
    if(!area.width) return;
    const narrow = area.width < 620, cw = Math.max(area.width, 620), ch = narrow ? cw*SH/SW : area.height;
    CW = cw; CH = ch; kFit = Math.min(cw/SW, ch/SH);
    const pw = Math.round(cw*devicePixelRatio), ph = Math.round(ch*devicePixelRatio);
    if(cv.width !== pw || cv.height !== ph){ cv.width = pw; cv.height = ph; cv.style.width = cw + "px"; cv.style.height = ch + "px"; }
    applyView();
  }

  // ---------------------------------------------------------------- the camera: turn, zoom, pan

  // The scale and offset that put cam's centre in the middle of the canvas at cam's zoom, keeping at least a fifth
  // of the drawing in view.
  function applyView(){
    if(!G || !CW) return;
    dims();
    kFit = Math.min(CW/SW, CH/SH);
    k = kFit*cam.zoom;
    let d = cam.cx === null ? {x:SW/2, y:SH/2} : P(cam.cx, cam.cy, 0);
    const vw = CW/k, vh = CH/k, mx = .2*Math.min(SW, vw), my = .2*Math.min(SH, vh);
    const cx = Math.min(SW - mx + vw/2, Math.max(mx - vw/2, d.x)), cy = Math.min(SH - my + vh/2, Math.max(my - vh/2, d.y));
    if(cam.cx !== null && (cx !== d.x || cy !== d.y)){ const f = floorAt(cx, cy); cam.cx = f.x; cam.cy = f.y; }
    d = {x:cx, y:cy};
    ox = CW/2 - d.x*k; oy = CH/2 - d.y*k;
  }
  const VIEW_KEY = "hive.classroom.view";
  let storeTimer = null;
  function store(){
    clearTimeout(storeTimer);
    storeTimer = setTimeout(() => { try { localStorage.setItem(VIEW_KEY, JSON.stringify(cam)); } catch {} }, 250);
  }
  function restore(){
    try {
      const v = JSON.parse(localStorage.getItem(VIEW_KEY) || "null");
      if(!v || typeof v !== "object") return;
      cam.view = v.view === "angled" ? "angled" : "straight";
      cam.rot = [0, 1, 2, 3].includes(v.rot) ? v.rot : 0;
      cam.zoom = Math.min(ZOOM_MAX, Math.max(ZOOM_MIN, Number(v.zoom) || 1));
      const ok = Number.isFinite(v.cx) && Number.isFinite(v.cy);
      cam.cx = ok ? v.cx : null; cam.cy = ok ? v.cy : null;
    } catch {}
  }
  // The floor point (tiles) at the middle of the canvas.
  const middle = () => floorAt((CW/2 - ox)/k, (CH/2 - oy)/k);
  // Zooms by a factor about a point on the canvas (CSS pixels), keeping what's under it in place.
  function zoomAt(px, py, factor){
    applyView();
    const d = {x:(px - ox)/k, y:(py - oy)/k}, z = Math.min(ZOOM_MAX, Math.max(ZOOM_MIN, cam.zoom*factor));
    if(z === cam.zoom) return;
    const k2 = kFit*z, f = floorAt((CW/2 - (px - d.x*k2))/k2, (CH/2 - (py - d.y*k2))/k2);
    cam.zoom = z; cam.cx = f.x; cam.cy = f.y;
    applyView(); store();
  }
  // Moves the view by a distance in CSS pixels: what's drawn moves with it.
  function panBy(dx, dy){
    applyView();
    const f = floorAt((CW/2 - ox - dx)/k, (CH/2 - oy - dy)/k);
    cam.cx = f.x; cam.cy = f.y;
    applyView(); store();
  }
  function fitView(){ cam.zoom = 1; cam.cx = null; cam.cy = null; applyView(); store(); }
  // A quarter turn (dir 1 clockwise, -1 the other way), about the middle of the canvas. A fitted view stays fitted.
  const snap = document.createElement("canvas"), still = document.createElement("canvas");
  let turning = null;
  function rotate(dir){
    if(!cv || !G || cam.view !== "angled") return;
    applyView();
    if(!calm.matches && cv.width){ snap.width = cv.width; snap.height = cv.height; snap.getContext("2d").drawImage(cv, 0, 0); turning = {from:performance.now(), dir}; }
    const f = middle(), fitted = cam.cx === null;
    cam.rot = (cam.rot + dir + 4) % 4;
    if(!fitted){ cam.cx = f.x; cam.cy = f.y; }
    applyView(); store();
  }
  // Switches between the straight and the angled view, keeping the same floor point in the middle.
  function setView(v){
    v = v === "angled" ? "angled" : "straight";
    if(!cv || !G || v === cam.view){ cam.view = v; syncControls(); return; }
    applyView();
    if(!calm.matches && cv.width){ snap.width = cv.width; snap.height = cv.height; snap.getContext("2d").drawImage(cv, 0, 0); turning = {from:performance.now(), dir:0}; }
    const f = middle(), fitted = cam.cx === null;
    cam.view = v;
    if(!fitted){ cam.cx = f.x; cam.cy = f.y; }
    size(); store(); syncControls();   // the two views differ in size, so the fitted scale changes
  }
  // The view buttons: which view is pressed, and the turn buttons only in the angled view.
  function syncControls(){
    const angled = cam.view === "angled", $ = id => document.getElementById(id);
    $("roomViewStraight")?.setAttribute("aria-pressed", String(!angled));
    $("roomViewAngled")?.setAttribute("aria-pressed", String(angled));
    for(const id of ["roomRotL", "roomRotR", "roomRotSep"]){ const el = $(id); if(el) el.hidden = !angled; }
  }
  // The turn's animation: the old view swings out and fades while the new one swings in, over 250 ms.
  function turnEffect(){
    if(!turning) return;
    const p = Math.min(1, (performance.now() - turning.from)/250);
    if(p >= 1){ turning = null; return; }
    const e = 1 - (1 - p)**3, ang = .32*turning.dir, w = cv.width, h = cv.height;
    still.width = w; still.height = h;
    const sc = still.getContext("2d"); sc.clearRect(0, 0, w, h); sc.drawImage(cv, 0, 0);
    ctx.setTransform(1, 0, 0, 1, 0, 0); ctx.clearRect(0, 0, w, h);
    const put = (img, a, alpha, s) => { ctx.save(); ctx.globalAlpha = alpha; ctx.translate(w/2, h/2); ctx.rotate(a); ctx.scale(s, s); ctx.translate(-w/2, -h/2); ctx.drawImage(img, 0, 0); ctx.restore(); };
    put(snap, ang*e, 1 - e, 1 - .05*e);
    put(still, -ang*(1 - e), e, .95 + .05*e);
    begin();
  }

  // A pointer event in drawing units.
  const local = e => { applyView(); const r = cv.getBoundingClientRect(); return {x:(e.clientX - r.left - ox)/k, y:(e.clientY - r.top - oy)/k}; };
  // The character under the pointer: the front-most one drawn there, or the owner of the desk or plate there.
  function at(e){
    const p = local(e);
    for(let i = hitList.length - 1; i >= 0; i--){
      const r = hitList[i];
      if(p.x >= r.x && p.x <= r.x + r.w && p.y >= r.y && p.y <= r.y + r.h){ const a = agents.get(r.id); if(a) return a; }
    }
    return null;
  }
  const typingIn = el => /INPUT|TEXTAREA|SELECT/.test(el?.tagName || "") || el?.isContentEditable;
  function init(canvas, pick){
    cv = canvas; ctx = cv.getContext("2d"); onPick = pick;
    restore();
    new ResizeObserver(size).observe(cv.parentElement);
    // Panning: drag empty floor (in edit mode, hold space and drag, since a plain drag moves things).
    let pan = null, spaceHeld = false, swallowClick = false;
    cv.addEventListener("pointerdown", e => {
      if(e.button !== 0) return;
      if(draft ? !spaceHeld : at(e)) return;
      pan = {x:e.clientX, y:e.clientY, moved:false, id:e.pointerId};
      try { cv.setPointerCapture(e.pointerId); } catch {}
      if(draft){ e.stopImmediatePropagation(); e.preventDefault(); }
    });
    cv.addEventListener("pointermove", e => {
      if(pan){
        const dx = e.clientX - pan.x, dy = e.clientY - pan.y;
        if(!pan.moved && Math.hypot(dx, dy) < 4) return;
        pan.moved = true; pan.x = e.clientX; pan.y = e.clientY;
        panBy(dx, dy); cv.style.cursor = "grabbing";
        if(draft) e.stopImmediatePropagation();
        return;
      }
      if(draft){ if(spaceHeld){ cv.style.cursor = "grab"; e.stopImmediatePropagation(); } return; }
      const a = at(e); hover = a?.s.id || null; pointerOn = hover; cv.style.cursor = a ? "pointer" : "grab";
      const tip = document.getElementById("tip");
      if(a){ tip.textContent = ""; const b = document.createElement("b"); b.textContent = a.s.name; tip.append(b, document.createElement("br"), a.s.headline || ""); tip.style.display = "block"; tip.style.left = Math.min(innerWidth - tip.offsetWidth - 8, e.clientX + 14) + "px"; tip.style.top = e.clientY + 14 + "px"; }
      else tip.style.display = "none";
    });
    const endPan = e => {
      if(!pan) return;
      if(pan.moved) swallowClick = true;
      pan = null; cv.style.cursor = draft ? (spaceHeld ? "grab" : "default") : "grab";
      if(draft) e.stopImmediatePropagation();
    };
    cv.addEventListener("pointerup", endPan);
    cv.addEventListener("pointercancel", endPan);
    cv.addEventListener("click", e => {
      if(swallowClick){ swallowClick = false; return; }
      if(draft) return;
      const s = at(e)?.s; onPick(s?.parent || s?.id || null);
    });
    cv.addEventListener("pointerleave", () => { hover = null; pointerOn = null; document.getElementById("tip").style.display = "none"; });
    // Wheel: with ctrl (and trackpad pinches, which arrive that way) zooms about the pointer; otherwise pans.
    cv.addEventListener("wheel", e => {
      e.preventDefault();
      const unit = e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? CH : 1;
      if(e.ctrlKey){
        const r = cv.getBoundingClientRect();
        zoomAt(e.clientX - r.left, e.clientY - r.top, Math.min(1.25, Math.max(.8, Math.exp(-e.deltaY*unit*.01))));
      } else panBy(-e.deltaX*unit, -e.deltaY*unit);
    }, {passive:false});
    // Keys: [ and ] turn the room; space held down lets a drag pan in edit mode.
    addEventListener("keydown", e => {
      if(!active || typingIn(document.activeElement) || e.metaKey || e.ctrlKey || e.altKey) return;
      if(e.key === " " && draft){
        const el = document.activeElement;
        if(!el || el === document.body || el === cv){ e.preventDefault(); if(!spaceHeld){ spaceHeld = true; cv.style.cursor = "grab"; } }
        return;
      }
      if((e.key === "[" || e.key === "]") && cam.view === "angled" && !document.querySelector("dialog[open]")){ e.preventDefault(); rotate(e.key === "]" ? 1 : -1); }
    });
    addEventListener("keyup", e => { if(e.key === " " && spaceHeld){ spaceHeld = false; if(!pan) cv.style.cursor = "default"; } });
    addEventListener("blur", () => { spaceHeld = false; });
    // The view buttons, when the page has them.
    const on = (id, fn) => document.getElementById(id)?.addEventListener("click", fn);
    on("roomRotL", () => rotate(-1));
    on("roomRotR", () => rotate(1));
    on("roomZoomIn", () => zoomAt(CW/2, CH/2, 1.25));
    on("roomZoomOut", () => zoomAt(CW/2, CH/2, .8));
    on("roomFit", fitView);
    on("roomViewStraight", () => setView("straight"));
    on("roomViewAngled", () => setView("angled"));
    syncControls();
  }
  // Enters edit mode with a draft room, or leaves it with null. view: {selected: id, ghost: {id, kind, x, y, bad}}.
  function edit(d, v){
    const was = draft;
    draft = d || null; view = v || {};
    if(!G) build();
    dims();
    if(cv && (!was !== !draft || was?.cols !== draft?.cols || was?.rows !== draft?.rows)) size();
    if(draft){ hover = null; pointerOn = null; const tip = document.getElementById("tip"); if(tip) tip.style.display = "none"; }
    else { editHits = null; if(cv) cv.style.cursor = "default"; }
    if(!draft && was){ for(const a of agents.values()){ a.path = []; a.nextMove = 0; a.retry = 0; if(!a.leaving) a.dest = null; } }
  }
  // The tile under a pointer event, in room tiles: on the floor, or on the back wall above it when the back wall
  // is in view (straight on it faces you; angled, it's the far wall along b = 0 in the first turn and a = 0 in the last).
  function tileAt(e){
    const p = local(e), f = floorAt(p.x, p.y);
    if(f.y >= WR || !backShown()) return {x:Math.floor(f.x), y:Math.floor(f.y)};
    let x, z;
    if(straight){ x = f.x; z = Y0 - p.y; }
    else if(rot === 0){ const a = (p.x - X0)/HW; x = a; z = Y0 + a*HH - p.y; }
    else { const b = (X0 - p.x)/HW; x = unturn(0, b)[0]; z = Y0 + b*HH - p.y; }
    return {x:Math.floor(x), y:Math.floor(WR - z/WZ)};
  }
  // In edit mode, the id of the item drawn under a pointer event (its whole shape, not only its footprint), or
  // null; undefined outside edit mode.
  function itemAt(e){
    if(!draft || !editHits) return undefined;
    const p = local(e);
    const inside = pts => { let yes = false; for(let i = 0, j = pts.length - 1; i < pts.length; j = i++){ const a = pts[i], b = pts[j]; if((a.y > p.y) !== (b.y > p.y) && p.x < (b.x - a.x)*(p.y - a.y)/(b.y - a.y) + a.x) yes = !yes; } return yes; };
    for(let i = editHits.length - 1; i >= 0; i--) if(inside(editHits[i].poly)) return editHits[i].id;
    return null;
  }
  const themeColour = name => { const v = css(name); return /^#[0-9a-f]{6}$/i.test(v) ? v : "#cccccc"; };
  return {init, update, setRoom, edit, tileAt, itemAt, themeColour, editing:() => !!draft, problem:() => problem, room:() => (G || (build(), G)).room, saved:() => saved,
    rotate, setView, fit:fitView, zoom:f => zoomAt(CW/2, CH/2, f), view:() => ({...cam}),
    setActive(on){ if(on === active) return; active = on; if(on){ restore(); syncControls(); size(); requestAnimationFrame(frame); } }, select(id){ sel = id; }, highlight(id){ hover = id; pointerOn = null; }, say:a => textOf({s:a})};
})();
