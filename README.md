# Rumbo

API de tracking en tiempo real y ETA, multi-proyecto. Cualquier aplicación
(delivery, flotas, técnicos en campo) crea un proyecto, obtiene una API key y
tiene tracking en vivo por WebSocket sin construir infraestructura propia.

```
dispositivo ──HTTP/WS──▶ Rumbo ──WebSocket──▶ mapa del cliente
   (GPS)                 │  posiciones, online/offline, ETA en vivo
                         └─ Postgres (histórico) + motor de ETA pluggable
```

## Conceptos

| Concepto    | Qué es |
|-------------|--------|
| **Project** | Tenant. Aislamiento total: API keys, trackers y trips propios. |
| **Tracker** | Lo que se mueve (`driver_42`, `van_7`). Se crea solo con el primer ping. |
| **Trip**    | Sesión con destino y paradas. Es el contexto del ETA. Un trip activo por tracker. |
| **Position**| Ping GPS: `lat`, `lng`, `speed`, `heading`, `accuracy`, `battery`, `recorded_at`, `metadata`. |

## Inicio rápido

Requisitos: Elixir ≥ 1.15 y Postgres (hay uno listo en Docker):

```bash
docker start rumbo-postgres   # contenedor en puerto 5433 (ver config/dev.exs)
mix setup                        # deps + DB + seeds (imprime la API key del proyecto demo)
mix phx.server                   # http://localhost:4000
```

Crear un proyecto para tu aplicación:

```bash
mix rumbo.gen.project "BetterRoute"
# => imprime el project id y la API key (rk_...) una sola vez
```

### 1. Enviar posiciones (dispositivo / backend)

```bash
curl -X POST http://localhost:4000/v1/trackers/driver_42/positions \
  -H "Authorization: Bearer rk_..." \
  -H "Content-Type: application/json" \
  -d '{"lat": -12.0464, "lng": -77.0428, "speed": 8.3, "heading": 120}'
# => 202 {"data": {"accepted": 1, "tracker": "driver_42"}}
```

Batch para colas offline (idempotente: los reintentos con el mismo
`recorded_at` se deduplican solos):

```json
{"positions": [
  {"lat": -12.0464, "lng": -77.0428, "recorded_at": "2026-06-11T15:00:00Z"},
  {"lat": -12.0470, "lng": -77.0440, "recorded_at": "2026-06-11T15:00:30Z"}
]}
```

Se aceptan alias comunes de llaves: `latitude`, `lon`, `longitude`, `bearing`,
`batteryLevel`, `timestamp` (unix en segundos o ms).

### 2. Crear un trip (para tener ETA)

```bash
curl -X POST http://localhost:4000/v1/trips \
  -H "Authorization: Bearer rk_..." -H "Content-Type: application/json" \
  -d '{
    "tracker": "driver_42",
    "waypoints": [{"lat": -12.05, "lng": -77.08, "name": "Parada 1", "id": "stop_1"}],
    "destination": {"lat": -12.0667, "lng": -77.1500, "name": "Cliente"},
    "metadata": {"order_id": "ORD-123"}
  }'
# => 201 {"data": {"id": "<trip_id>", "status": "active", ...}}
```

A medida que se completan paradas, actualiza los waypoints restantes y el ETA
se recalcula contra la ruta nueva:

```bash
curl -X PATCH http://localhost:4000/v1/trips/<trip_id> \
  -H "Authorization: Bearer rk_..." -H "Content-Type: application/json" \
  -d '{"waypoints": []}'          # ya solo queda el destino

# al entregar:
curl -X PATCH ... -d '{"status": "completed"}'
```

### 3. Token para el cliente final

La API key nunca viaja al browser/app. Tu backend pide un token efímero con
scopes mínimos:

```bash
curl -X POST http://localhost:4000/v1/tokens \
  -H "Authorization: Bearer rk_..." -H "Content-Type: application/json" \
  -d '{"subscribe": ["trip:<trip_id>"], "ttl_seconds": 3600}'
# => 201 {"data": {"token": "...", "expires_at": "..."}}
```

Scopes: `tracker:<key>` / `trip:<id>`, wildcard de sufijo (`tracker:*`) o `*`.
`subscribe` permite escuchar; `publish` permite emitir posiciones por el socket.

### 4. Suscribirse en tiempo real

JavaScript (`npm install phoenix`):

```js
import { Socket } from "phoenix"

const socket = new Socket("ws://localhost:4000/socket", { params: { token } })
socket.connect()

const channel = socket.channel(`trip:${tripId}`)
channel.join().receive("ok", snapshot => render(snapshot)) // estado inicial

channel.on("position", p => moveMarker(p.lat, p.lng))
channel.on("eta", eta => showEta(eta.eta_at, eta.legs))     // legs: ETA por parada
channel.on("status", s => onTripStatus(s.status))           // completed / canceled
channel.on("tracker_status", s => setOnline(s.status === "online"))
```

Flutter (`phoenix_socket` en pub.dev) — reemplaza el polling de 60s:

```dart
final socket = PhoenixSocket('ws://host:4000/socket/websocket',
    socketOptions: PhoenixSocketOptions(params: {'token': token}));
await socket.connect();

final channel = socket.addChannel(topic: 'trip:$tripId');
await channel.join().future;

channel.messages.listen((msg) {
  switch (msg.event.value) {
    case 'position': updateMarker(msg.payload!);
    case 'eta':      updateEta(msg.payload!);   // payload['legs'] = ETA por parada
  }
});
```

La app del conductor también puede emitir por el socket en vez de HTTP
(token con `publish: ["tracker:driver_42"]`):

```dart
channel.push('position', {'lat': -12.05, 'lng': -77.04, 'speed': 8.3});
```

## Eventos

| Canal | Evento | Payload |
|-------|--------|---------|
| `tracker:<key>` | `position` | `{tracker, lat, lng, speed, heading, accuracy, altitude, battery, metadata, recorded_at, trip_id}` |
| `tracker:<key>` | `status` | `{tracker, status: "online"\|"offline", last_seen_at}` |
| `tracker:<key>` | `trip` | `{trip_id, tracker, status}` — trips creados/actualizados |
| `trip:<id>` | `position` | igual que arriba |
| `trip:<id>` | `eta` | `{trip_id, engine, distance_meters, duration_seconds, eta_at, calculated_at, legs: [{id?, name?, lat, lng, distance_meters, duration_seconds, eta_at}]}` |
| `trip:<id>` | `status` | `{trip_id, status, ended_at}` |
| `trip:<id>` | `tracker_status` | online/offline del tracker del trip |

El `join` de ambos canales responde un **snapshot** (último estado conocido)
para pintar el mapa sin esperar el primer evento.

## REST

Todas las rutas bajo `/v1` requieren `Authorization: Bearer rk_...`.

| Método | Ruta | Descripción |
|--------|------|-------------|
| POST | `/v1/trackers/:key/positions` | Ingesta (single o `{"positions": [...]}`) |
| POST | `/v1/positions` | Igual, con `"tracker"` en el body |
| GET | `/v1/trackers` | Lista con última posición y estado online |
| GET | `/v1/trackers/:key` | Detalle |
| PUT | `/v1/trackers/:key` | Crear/actualizar `name`, `metadata` |
| GET | `/v1/trackers/:key/positions?from=&to=&limit=` | Historial |
| POST | `/v1/trips` | Crear trip (activo) |
| GET | `/v1/trips?status=&tracker=` | Listar |
| GET | `/v1/trips/:id` | Detalle (incluye último `eta`) |
| PATCH | `/v1/trips/:id` | Estado / destino / waypoints / metadata |
| POST | `/v1/tokens` | Token efímero para clientes finales |
| GET | `/health` | Sin auth |

Errores siempre con la misma forma:

```json
{"error": {"code": "invalid_position", "message": "...", "details": {"index": 1}}}
```

## ETA

Motor pluggable por proyecto (`Rumbo.Eta.Engine`):

* **`haversine`** (default): distancia geodésica × factor de circuito (1.3),
  velocidad real suavizada del tracker con fallback configurable. Cero
  dependencias; precisión razonable para distancias urbanas cortas.
* **`osrm`**: rutas reales contra tu servidor OSRM.

```bash
# activar OSRM para un proyecto (psql / iex):
UPDATE projects SET settings = '{"eta": {"engine": "osrm", "osrm_url": "http://localhost:5000"}}'
WHERE slug = 'mi-proyecto';
```

El recálculo se dispara con cada ping pero se limita por throttle
(`throttle_seconds`: 30, `throttle_meters`: 150, configurables por proyecto).
El evento `eta` incluye `legs` con ETA acumulado por parada — esto reemplaza
el `liveEtaAt` por polling.

## Arquitectura

* **Un GenServer por tracker activo** (`TrackerServer`, vía `Registry` +
  `DynamicSupervisor`): última posición, velocidad suavizada, throttle de ETA,
  detección online/offline. Se apaga solo tras 30 min de inactividad.
  ~2-3 KB por proceso: un millón de trackers son ~3 GB.
* **PubSub interno por proyecto** (`proj:<id>:tracker:<key>`): los canales se
  suscriben en el join; dos proyectos con el mismo tracker key no se cruzan.
* **Auth en dos niveles**: API keys de servidor (hash SHA-256 en DB) y tokens
  firmados efímeros con scopes para clientes finales.

### Diseñado para volumen

* **Writer agregador global** (`PositionWriter`): N shards (uno por core)
  agrupan filas de *todos* los trackers y escriben lotes de hasta 1.000 con
  `INSERT ... ON CONFLICT DO NOTHING`; los snapshots de trackers se colapsan
  en un solo `UPDATE ... FROM unnest(...)` por lote. Un ping nunca espera a
  Postgres; si Postgres cae, el buffer retiene hasta 50k filas por shard con
  descarte de lo más antiguo (el realtime nunca se bloquea).
* **`positions` particionada por mes** (rango de `recorded_at`):
  `PartitionManager` crea las particiones futuras automáticamente y la
  partición `DEFAULT` recoge backfills antiguos. Retención = `DROP` de
  partición, no `DELETE` de millones de filas.
* **Clúster**: cada tracker tiene un nodo dueño determinista
  (`Rumbo.Cluster.owner_node/1`, hash sobre los nodos visibles); el
  ingest se reenvía con `:erpc.cast` y los eventos cruzan nodos vía
  Phoenix.PubSub distribuido. Con un nodo, cero overhead. Conecta los nodos
  con la estrategia que prefieras (DNSCluster ya viene configurado).
* **ETA acotado**: `Eta.Limiter` limita los cálculos concurrentes por nodo
  (`config :rumbo, eta_max_concurrency`, default 200) — sin avalanchas
  contra OSRM. `Eta.Breaker` abre el circuito por URL tras 5 fallos (30 s) y
  el cálculo degrada **automáticamente a haversine** (`degraded: true` en el
  evento `eta`): un OSRM caído nunca deja al cliente sin ETA.

## Despliegue en una VPS (Docker)

Todo el stack (API + Postgres) corre con Docker Compose en cualquier VPS:

```bash
git clone https://github.com/<tu-usuario>/rumbo && cd rumbo
cp .env.example .env        # completa SECRET_KEY_BASE y POSTGRES_PASSWORD
docker compose up -d --build
```

Las migraciones (y las particiones mensuales) se aplican solas en cada
arranque. Crea el primer proyecto y su API key:

```bash
docker compose exec app /app/bin/rumbo eval 'Rumbo.Release.gen_project("Mi App")'
```

La API queda en `http://<vps>:4000` (`RUMBO_PORT` para cambiarlo). En
producción pon un reverse proxy con TLS delante (Caddy lo hace en dos líneas):

```
tracking.miapp.com {
    reverse_proxy localhost:4000
}
```

Variables soportadas: `SECRET_KEY_BASE`, `POSTGRES_PASSWORD`, `PHX_HOST`,
`RUMBO_PORT`, `CHECK_ORIGIN` (orígenes WebSocket, default abierto),
`POOL_SIZE`, `DATABASE_URL` (si usas un Postgres externo al compose).

El `Dockerfile` produce un release OTP autocontenido (multi-stage, corre como
`nobody`): también sirve para Fly.io, Railway, Dokku o Kubernetes.

## Tests

```bash
mix test
```

## Roadmap

* Detección de llegada (auto-completar waypoints por radio)
* Gestión de API keys por REST + rotación
* Webhooks (trip completado, tracker offline)
* Rate limiting por proyecto
