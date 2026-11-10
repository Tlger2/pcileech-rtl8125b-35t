export const HELP: Record<string, string> = {
  dma: "FT601 MAGIC identify/read or MemProcFS snapshot ingest. SIM runs a live world until a bridge is on :1738 / :8080. Disconnect drops back to SIM. Reload Radar reseeds or re-pulls entities. The radar is read-only — it never writes game memory.",
  map: "Reload Map rebuilds the procedural island from the current seed and auto-formats like opening the G-map (center on you, ~750m view). Interactive camera lets you free-pan without following the local player. Follow-cam stays on while Interactive camera is off.",
  chams: "Full Pink paints every visible player magenta. Not see hides player meshes on the radar except the ESP widget. Default uses team/enemy colors.",
  vis: "Visibility Check Chams runs a heightmap LOS test and dims players behind terrain.",
  adminEsp: "Admin ESP keeps IsAdmin players on a distinct gold marker even when other player filters are tight.",
  camera: "Interactive camera detaches follow-cam after join auto-format. Drag to pan, wheel to zoom, F to refocus local. Join / first spawn / Reload Map still snap the G-map framing once.",
  night: "Bright Night lifts terrain luminance so night wipes do not hide nodes.",
  caves: "Bright Caves keeps cave/collectible nodes painted instead of eating them with shadow.",
};
