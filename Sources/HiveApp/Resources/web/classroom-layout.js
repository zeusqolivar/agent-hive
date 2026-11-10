/* Classroom desk assignment: who sits at which desk. Pure functions, used by room.js in the browser and by tests in Node. */
"use strict";
(function(root){
  // Who sits where. A session keeps its desk; the room is resized at most once a minute, and only when the
  // desk count changes, unless someone arrives and every desk is taken. liveIds are ordered by startedAt.
  function assignDesks(state, liveIds, now){
    const wanted = liveIds.length + 1;
    const prev = state.assign || {}, assign = {};
    for(const id of liveIds) if(Object.hasOwn(prev, id)) assign[id] = prev[id];
    const arriving = liveIds.filter(id => !Object.hasOwn(assign, id));
    const free = state.deskCount - Object.keys(assign).length;
    const rearrange = state.deskCount !== wanted && (!state.deskCount || now - state.layoutAt >= 60 || arriving.length > free);
    if(rearrange){
      const order = liveIds.map((id, i) => ({id, i, d: Object.hasOwn(prev, id) ? prev[id] : Infinity}))
        .sort((p, q) => p.d - q.d || p.i - q.i);
      const next = {};
      order.forEach((o, desk) => { next[o.id] = desk; });
      return {deskCount: wanted, layoutAt: now, assign: next};
    }
    const used = new Set(Object.values(assign));
    let desk = 0;
    for(const id of arriving){
      while(used.has(desk)) desk++;
      assign[id] = desk; used.add(desk);
    }
    return {deskCount: state.deskCount, layoutAt: state.layoutAt, assign};
  }

  const api = {assignDesks};
  if(typeof module === "object" && module.exports) module.exports = api;
  else root.ClassroomLayout = api;
})(typeof globalThis !== "undefined" ? globalThis : this);
