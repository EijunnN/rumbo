// Smoke test de punta a punta contra un servidor Rumbo corriendo en dev.
// Corre con: bun run scripts/smoke.ts <api_key>
//
// Flujo: crea un trip → emite token → se suscribe por WebSocket (protocolo
// Phoenix Channels v2) → ingesta una posición por REST → verifica que lleguen
// los eventos position y eta en vivo.

const BASE = "http://localhost:4000";
const API_KEY = process.argv[2];
if (!API_KEY) throw new Error("Uso: bun run scripts/smoke.ts <api_key>");

const headers = { Authorization: `Bearer ${API_KEY}`, "Content-Type": "application/json" };
const tracker = `smoke_${Date.now()}`;

async function api(method: string, path: string, body?: unknown) {
  const res = await fetch(`${BASE}${path}`, {
    method,
    headers,
    body: body ? JSON.stringify(body) : undefined,
  });
  const json = (await res.json()) as any;
  if (!res.ok) throw new Error(`${method} ${path} -> ${res.status}: ${JSON.stringify(json)}`);
  return json.data;
}

// 1. Salud y trip
const health = await fetch(`${BASE}/health`).then((r) => r.json());
console.log("health:", health);

const trip = await api("POST", "/v1/trips", {
  tracker,
  waypoints: [{ lat: -12.05, lng: -77.08, name: "Parada 1" }],
  destination: { lat: -12.0667, lng: -77.15, name: "Cliente" },
});
console.log("trip creado:", trip.id, trip.status);

// 2. Token de suscriptor (como lo haría el backend del consumidor)
const token = await api("POST", "/v1/tokens", { subscribe: [`trip:${trip.id}`] });
console.log("token emitido, expira:", token.expires_at);

// 3. WebSocket con el wire protocol de Phoenix (serializer v2)
const ws = new WebSocket(`ws://localhost:4000/socket/websocket?token=${token.token}&vsn=2.0.0`);
const received = new Map<string, any>();

const done = new Promise<void>((resolve, reject) => {
  const timeout = setTimeout(() => reject(new Error("timeout esperando eventos")), 10_000);

  ws.onmessage = (msg) => {
    const [, , topic, event, payload] = JSON.parse(msg.data as string);
    if (event === "phx_reply" && payload.status === "ok" && payload.response.trip) {
      console.log("join ok, snapshot trip:", payload.response.trip.status);
      // 4. Con el canal ya unido, ingesta por REST → debe llegar por WS
      api("POST", `/v1/trackers/${tracker}/positions`, {
        lat: -12.0464,
        lng: -77.0428,
        speed: 9.5,
        heading: 245,
      }).then((r) => console.log("posición aceptada:", r));
    }
    if (event === "position" || event === "eta" || event === "tracker_status") {
      console.log(`evento "${event}":`, JSON.stringify(payload).slice(0, 200));
      received.set(event, payload);
      if (received.has("position") && received.has("eta")) {
        clearTimeout(timeout);
        resolve();
      }
    }
  };
  ws.onerror = (e) => reject(new Error(`websocket error: ${e}`));
});

ws.onopen = () => {
  // [join_ref, ref, topic, event, payload]
  ws.send(JSON.stringify(["1", "1", `trip:${trip.id}`, "phx_join", {}]));
};

await done;

const eta = received.get("eta");
if (eta.legs.length !== 2) throw new Error("se esperaban 2 legs (parada + destino)");
console.log(`\nETA en vivo: ${eta.duration_seconds}s (${Math.round(eta.distance_meters / 100) / 10} km), llegada ${eta.eta_at}`);
console.log("ETA Parada 1:", eta.legs[0].eta_at);

// 5. Completar el trip y cerrar
await api("PATCH", `/v1/trips/${trip.id}`, { status: "completed" });
console.log("trip completado");

ws.close();
console.log("\nSMOKE TEST OK ✔");
process.exit(0);
