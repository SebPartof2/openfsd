package fsd

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"math"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/renorris/openfsd/db"
)

// navMode describes how a simulated aircraft determines its target heading.
type navMode int

const (
	navHeading navMode = iota // hold the assigned heading
	navLNAV                   // follow a route of waypoints
)

// waypoint is a single navigation fix, optionally with an altitude restriction.
type waypoint struct {
	Name string  `json:"name"`
	Lat  float64 `json:"lat"`
	Lon  float64 `json:"lon"`
	Alt  int     `json:"alt"` // altitude restriction in feet; 0 = none
}

// simAircraft wraps a *Client with simulation-only navigation state.
//
// The embedded *Client carries the live, broadcast-facing values (position,
// heading, altitude, speed, track owner) as atomics. Fields guarded by mu hold
// the higher-level lateral-navigation intent.
type simAircraft struct {
	*Client

	mu           sync.Mutex
	navMode      navMode
	route        []waypoint
	climbRateFpm int
}

// simManager owns all server-side simulated aircraft.
//
// A simulated aircraft is an ordinary *Client (registered in the post office and
// visible to every controller) whose position is advanced by a flight model on a
// fixed timer instead of by inbound position packets. Aircraft persist
// independently of the controller who created them, and across server restarts
// when a durable database is configured. Maneuver authority follows the FSD
// track: whichever controller currently holds the track may issue commands.
type simManager struct {
	srv *Server
	ctx context.Context

	aircraft map[string]*simAircraft // callsign -> simulated aircraft
	mu       sync.RWMutex

	fixes   map[string]LatLon // name -> location
	fixesMu sync.RWMutex

	nextCID int
}

const (
	simTickHz           = 4                // flight-model integration rate
	simBroadcastEveryN  = 4                // broadcast a position every N ticks (~1 Hz)
	simTurnRate         = 3.0              // degrees per second (standard rate)
	simDefaultClimbFpm  = 1800             // default vertical rate (feet per minute)
	simAccelRate        = 5.0              // knots per second
	simDefaultVisRange  = 50.0 * 1852.0    // meters (matches real pilot clients)
	simDefaultSquawk    = "2000"           // default transponder code
	simCaptureNM        = 1.0              // waypoint capture distance in nautical miles
	simSnapshotInterval = 10 * time.Second // how often aircraft state is persisted
)

func newSimManager(srv *Server) *simManager {
	return &simManager{
		srv:      srv,
		aircraft: make(map[string]*simAircraft, 64),
		fixes:    make(map[string]LatLon, 256),
		nextCID:  8000001,
	}
}

// find returns the simulated aircraft with the given callsign, or nil.
func (m *simManager) find(callsign string) *simAircraft {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.aircraft[callsign]
}

// repo returns the simulated-aircraft persistence repository, or nil.
func (m *simManager) repo() db.SimAircraftRepository {
	if m.srv == nil || m.srv.dbRepo == nil {
		return nil
	}
	return m.srv.dbRepo.SimAircraftRepo
}

// aircraftState is the JSON-serializable snapshot persisted to the database.
type aircraftState struct {
	Callsign          string     `json:"callsign"`
	Lat               float64    `json:"lat"`
	Lon               float64    `json:"lon"`
	Heading           int        `json:"heading"`
	Altitude          int        `json:"altitude"`
	Groundspeed       int        `json:"groundspeed"`
	TargetHeading     int        `json:"target_heading"`
	TargetAltitude    int        `json:"target_altitude"`
	TargetGroundspeed int        `json:"target_groundspeed"`
	Transponder       string     `json:"transponder"`
	Creator           string     `json:"creator"`
	ClimbRateFpm      int        `json:"climb_rate_fpm"`
	NavMode           int        `json:"nav_mode"`
	Route             []waypoint `json:"route"`
}

// create instantiates a simulated aircraft from a state snapshot, registers it,
// and announces it to the network. If track is non-empty, that controller is
// given the aircraft's track.
func (m *simManager) create(st aircraftState, track string) (*simAircraft, error) {
	if !isValidClientCallsign([]byte(st.Callsign)) {
		return nil, fmt.Errorf("invalid callsign")
	}

	m.mu.Lock()
	cid := m.nextCID
	m.nextCID++
	m.mu.Unlock()

	data := loginData{
		callsign:         st.Callsign,
		cid:              cid,
		realName:         "Simulated Aircraft",
		networkRating:    NetworkRatingObserver,
		maxNetworkRating: NetworkRatingObserver,
		protoRevision:    100,
		loginTime:        time.Now(),
		isAtc:            false,
	}

	c := newClient(m.ctx, newVirtualConn(), nil, data)
	c.isVirtual = true
	c.creator = st.Creator
	if track != "" {
		c.controllingController.Store(track)
	}

	squawk := st.Transponder
	if squawk == "" {
		squawk = simDefaultSquawk
	}
	c.transponder.Store(squawk)
	c.setLatLon(st.Lat, st.Lon)
	c.visRange.Store(simDefaultVisRange)
	c.heading.Store(int32(st.Heading))
	c.altitude.Store(int32(st.Altitude))
	c.groundspeed.Store(int32(st.Groundspeed))
	c.targetHeading.Store(int32(st.TargetHeading))
	c.targetAltitude.Store(int32(st.TargetAltitude))
	c.targetGroundspeed.Store(int32(st.TargetGroundspeed))
	c.lastUpdated.Store(time.Now())

	climb := st.ClimbRateFpm
	if climb <= 0 {
		climb = simDefaultClimbFpm
	}

	ac := &simAircraft{
		Client:       c,
		navMode:      navMode(st.NavMode),
		route:        st.Route,
		climbRateFpm: climb,
	}

	if err := m.srv.postOffice.register(c); err != nil {
		return nil, err
	}

	m.mu.Lock()
	m.aircraft[st.Callsign] = ac
	m.mu.Unlock()

	// Drain the outbound channel (writes are discarded by the virtual conn) so
	// that broadcasts targeting this aircraft never block their sender.
	go c.senderWorker()

	// Announce the new aircraft to every connected client.
	m.srv.broadcastAddPacket(c)

	return ac, nil
}

// spawn creates a new simulated aircraft tracked by the given creator.
func (m *simManager) spawn(creator, callsign string, lat, lon float64, hdg, alt, spd int) (*simAircraft, error) {
	h := int(normalizeHeading(float64(hdg)))
	st := aircraftState{
		Callsign:          callsign,
		Lat:               lat,
		Lon:               lon,
		Heading:           h,
		Altitude:          alt,
		Groundspeed:       spd,
		TargetHeading:     h,
		TargetAltitude:    alt,
		TargetGroundspeed: spd,
		Transponder:       simDefaultSquawk,
		Creator:           creator,
		ClimbRateFpm:      simDefaultClimbFpm,
		NavMode:           int(navHeading),
	}

	ac, err := m.create(st, creator)
	if err != nil {
		return nil, err
	}
	m.persist(ac)
	return ac, nil
}

// remove deletes a simulated aircraft from the network and from persistence.
func (m *simManager) remove(callsign string) bool {
	m.mu.Lock()
	ac := m.aircraft[callsign]
	delete(m.aircraft, callsign)
	m.mu.Unlock()

	if ac == nil {
		return false
	}

	m.srv.broadcastDisconnectPacket(ac.Client)
	m.srv.postOffice.release(ac.Client)
	ac.cancelCtx()

	if repo := m.repo(); repo != nil {
		if err := repo.Delete(callsign); err != nil {
			slog.Debug("could not delete simulated aircraft: " + err.Error())
		}
	}
	return true
}

// releaseTracksFor clears the track on any aircraft controlled by the given
// controller. Called when a controller disconnects: their aircraft remain on the
// network (continuing their last clearance) but become untracked, so that any
// other controller may take over.
func (m *simManager) releaseTracksFor(controller string) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	for _, ac := range m.aircraft {
		if ac.controllingController.Load() == controller {
			ac.controllingController.Store("")
		}
	}
}

// setTrack records the controller currently holding an aircraft's track. Called
// when the server observes an Initiate Track (IT) or handoff acceptance (HT).
func (m *simManager) setTrack(callsign, controller string) {
	if ac := m.find(callsign); ac != nil {
		ac.controllingController.Store(controller)
	}
}

// dropTrack clears an aircraft's track if it is currently held by controller.
func (m *simManager) dropTrack(callsign, controller string) {
	if ac := m.find(callsign); ac != nil {
		if ac.controllingController.Load() == controller {
			ac.controllingController.Store("")
		}
	}
}

// defineFix registers (or replaces) a named navigation fix.
func (m *simManager) defineFix(name string, lat, lon float64) {
	m.fixesMu.Lock()
	m.fixes[strings.ToUpper(name)] = LatLon{lat: lat, lon: lon}
	m.fixesMu.Unlock()
}

// lookupFix resolves a named fix into a waypoint.
func (m *simManager) lookupFix(name string) (waypoint, bool) {
	m.fixesMu.RLock()
	ll, ok := m.fixes[strings.ToUpper(name)]
	m.fixesMu.RUnlock()
	if !ok {
		return waypoint{}, false
	}
	return waypoint{Name: strings.ToUpper(name), Lat: ll.lat, Lon: ll.lon}, true
}

// run executes the simulation loop until the context is cancelled.
func (m *simManager) run(ctx context.Context) {
	m.loadFromDB()

	ticker := time.NewTicker(time.Second / simTickHz)
	defer ticker.Stop()
	snapshotTicker := time.NewTicker(simSnapshotInterval)
	defer snapshotTicker.Stop()

	last := time.Now()
	tick := 0

	for {
		select {
		case <-ctx.Done():
			return
		case <-snapshotTicker.C:
			m.snapshotAll()
		case now := <-ticker.C:
			dt := now.Sub(last).Seconds()
			last = now
			tick++
			broadcast := tick%simBroadcastEveryN == 0

			m.mu.RLock()
			snapshot := make([]*simAircraft, 0, len(m.aircraft))
			for _, ac := range m.aircraft {
				snapshot = append(snapshot, ac)
			}
			m.mu.RUnlock()

			for _, ac := range snapshot {
				m.step(ac, dt, broadcast)
			}
		}
	}
}

// step advances a single aircraft's flight model by dt seconds and, when
// broadcast is true, transmits a position update to all in-range clients.
func (m *simManager) step(ac *simAircraft, dt float64, broadcast bool) {
	c := ac.Client
	ll := c.latLon()

	// Lateral navigation: when following a route, steer toward the active
	// waypoint and sequence to the next one upon capture.
	ac.mu.Lock()
	if ac.navMode == navLNAV && len(ac.route) > 0 {
		wp := ac.route[0]
		c.targetHeading.Store(int32(math.Round(bearing(ll[0], ll[1], wp.Lat, wp.Lon))))
		if distance(ll[0], ll[1], wp.Lat, wp.Lon) <= simCaptureNM*1852.0 {
			if wp.Alt != 0 {
				c.targetAltitude.Store(int32(wp.Alt))
			}
			ac.route = ac.route[1:]
			if len(ac.route) == 0 {
				ac.navMode = navHeading
			}
		}
	}
	climbFtPerSec := float64(ac.climbRateFpm) / 60.0
	ac.mu.Unlock()

	// Heading: turn toward the target heading at the standard rate.
	hdg := float64(c.heading.Load())
	hdg = stepHeading(hdg, float64(c.targetHeading.Load()), simTurnRate*dt)
	c.heading.Store(int32(math.Round(hdg)))

	// Altitude: climb or descend toward the target altitude.
	alt := float64(c.altitude.Load())
	alt = stepToward(alt, float64(c.targetAltitude.Load()), climbFtPerSec*dt)
	c.altitude.Store(int32(math.Round(alt)))

	// Groundspeed: accelerate or decelerate toward the target speed.
	gs := float64(c.groundspeed.Load())
	gs = stepToward(gs, float64(c.targetGroundspeed.Load()), simAccelRate*dt)
	c.groundspeed.Store(int32(math.Round(gs)))

	// Position: dead-reckon along the current heading.
	if gs > 0 {
		distNM := gs * dt / 3600.0
		hdgRad := hdg * degToRad
		newLat := ll[0] + (distNM/60.0)*math.Cos(hdgRad)
		newLon := ll[1]
		if cosLat := math.Cos(ll[0] * degToRad); cosLat != 0 {
			newLon = ll[1] + (distNM/60.0)*math.Sin(hdgRad)/cosLat
		}
		c.setLatLon(newLat, newLon)
		m.srv.postOffice.updatePosition(c, [2]float64{newLat, newLon}, simDefaultVisRange)
	}

	c.lastUpdated.Store(time.Now())

	if broadcast {
		broadcastRanged(m.srv.postOffice, c, []byte(buildPilotPositionPacket(c)))
	}
}

// loadFromDB restores persisted aircraft on startup. Restored aircraft are
// untracked and resume flying their last clearance.
func (m *simManager) loadFromDB() {
	repo := m.repo()
	if repo == nil {
		return
	}

	records, err := repo.LoadAll()
	if err != nil {
		slog.Debug("could not load simulated aircraft: " + err.Error())
		return
	}

	restored := 0
	for _, rec := range records {
		var st aircraftState
		if err := json.Unmarshal([]byte(rec.State), &st); err != nil {
			slog.Warn("could not decode simulated aircraft " + rec.Callsign + ": " + err.Error())
			continue
		}
		if _, err := m.create(st, ""); err != nil {
			slog.Warn("could not restore simulated aircraft " + rec.Callsign + ": " + err.Error())
			continue
		}
		restored++
	}

	if restored > 0 {
		slog.Info(fmt.Sprintf("restored %d simulated aircraft", restored))
	}
}

// snapshot builds a persistable snapshot of an aircraft's current state.
func (m *simManager) snapshot(ac *simAircraft) aircraftState {
	ac.mu.Lock()
	nav := ac.navMode
	route := append([]waypoint(nil), ac.route...)
	climb := ac.climbRateFpm
	ac.mu.Unlock()

	ll := ac.latLon()
	return aircraftState{
		Callsign:          ac.callsign,
		Lat:               ll[0],
		Lon:               ll[1],
		Heading:           int(ac.heading.Load()),
		Altitude:          int(ac.altitude.Load()),
		Groundspeed:       int(ac.groundspeed.Load()),
		TargetHeading:     int(ac.targetHeading.Load()),
		TargetAltitude:    int(ac.targetAltitude.Load()),
		TargetGroundspeed: int(ac.targetGroundspeed.Load()),
		Transponder:       ac.transponder.Load(),
		Creator:           ac.creator,
		ClimbRateFpm:      climb,
		NavMode:           int(nav),
		Route:             route,
	}
}

// persist writes a single aircraft's current state to the database.
func (m *simManager) persist(ac *simAircraft) {
	repo := m.repo()
	if repo == nil {
		return
	}
	data, err := json.Marshal(m.snapshot(ac))
	if err != nil {
		slog.Error("could not encode simulated aircraft: " + err.Error())
		return
	}
	if err := repo.Save(&db.SimAircraftRecord{Callsign: ac.callsign, State: string(data)}); err != nil {
		slog.Debug("could not persist simulated aircraft: " + err.Error())
	}
}

// snapshotAll persists the state of every simulated aircraft.
func (m *simManager) snapshotAll() {
	if m.repo() == nil {
		return
	}
	m.mu.RLock()
	all := make([]*simAircraft, 0, len(m.aircraft))
	for _, ac := range m.aircraft {
		all = append(all, ac)
	}
	m.mu.RUnlock()

	for _, ac := range all {
		m.persist(ac)
	}
}

// handleCommand parses and executes a controller's SIM command. Replies are sent
// back to the controller as text messages from the "SIM" pseudo-station.
func (m *simManager) handleCommand(controller *Client, body string) {
	fields := strings.Fields(body)
	if len(fields) == 0 {
		return
	}

	switch strings.ToUpper(fields[0]) {
	case "SPAWN":
		m.handleSpawnCommand(controller, fields[1:])
		return
	case "FIX":
		m.handleFixCommand(controller, fields[1:])
		return
	case "FIXES":
		m.fixesMu.RLock()
		n := len(m.fixes)
		m.fixesMu.RUnlock()
		m.reply(controller, fmt.Sprintf("%d fixes defined", n))
		return
	}

	// All other commands operate on an existing aircraft: <callsign> <cmd> [args]
	if len(fields) < 2 {
		m.reply(controller, "Usage: <callsign> <command> [value]")
		return
	}

	callsign := strings.ToUpper(fields[0])
	cmd := strings.ToUpper(fields[1])
	args := fields[2:]

	ac := m.find(callsign)
	if ac == nil {
		m.reply(controller, "No such simulated aircraft: "+callsign)
		return
	}

	// Maneuver authority requires holding the track.
	if ac.controllingController.Load() != controller.callsign {
		m.reply(controller, "You do not control "+callsign)
		return
	}

	value := ""
	if len(args) >= 1 {
		value = args[0]
	}

	switch cmd {
	case "FH", "H", "HDG": // fly heading (cancels LNAV)
		v, err := strconv.Atoi(value)
		if err != nil {
			m.reply(controller, "Invalid heading")
			return
		}
		ac.mu.Lock()
		ac.navMode = navHeading
		ac.route = nil
		ac.mu.Unlock()
		ac.targetHeading.Store(int32(normalizeHeading(float64(v))))
		m.reply(controller, callsign+" fly heading "+value)
	case "C", "D", "ALT": // climb/descend to altitude (feet)
		v, err := strconv.Atoi(value)
		if err != nil {
			m.reply(controller, "Invalid altitude")
			return
		}
		ac.targetAltitude.Store(int32(v))
		m.reply(controller, callsign+" maintain "+value)
	case "S", "SPD": // assign speed (knots)
		v, err := strconv.Atoi(value)
		if err != nil {
			m.reply(controller, "Invalid speed")
			return
		}
		ac.targetGroundspeed.Store(int32(v))
		m.reply(controller, callsign+" speed "+value)
	case "VS": // assign vertical rate (feet per minute)
		v, err := strconv.Atoi(value)
		if err != nil || v <= 0 {
			m.reply(controller, "Invalid vertical rate")
			return
		}
		ac.mu.Lock()
		ac.climbRateFpm = v
		ac.mu.Unlock()
		m.reply(controller, callsign+" vertical rate "+value+" fpm")
	case "SQ", "SQUAWK": // assign squawk code
		if value == "" {
			m.reply(controller, "Invalid squawk")
			return
		}
		ac.transponder.Store(value)
		m.reply(controller, callsign+" squawk "+value)
	case "DCT", "DIRECT": // proceed direct to a fix or coordinate
		m.handleDirect(controller, ac, args)
	case "ROUTE": // follow a sequence of fixes
		m.handleRoute(controller, ac, args)
	case "DEL", "DELETE", "KILL":
		m.remove(callsign)
		m.reply(controller, callsign+" removed")
		return
	default:
		m.reply(controller, "Unknown command: "+cmd)
		return
	}

	m.persist(ac)
}

func (m *simManager) handleSpawnCommand(controller *Client, args []string) {
	// SPAWN <callsign> <lat> <lon> <hdg> <alt> <spd>
	if len(args) < 6 {
		m.reply(controller, "Usage: SPAWN <callsign> <lat> <lon> <hdg> <alt> <spd>")
		return
	}

	callsign := strings.ToUpper(args[0])
	lat, err1 := strconv.ParseFloat(args[1], 64)
	lon, err2 := strconv.ParseFloat(args[2], 64)
	hdg, err3 := strconv.Atoi(args[3])
	alt, err4 := strconv.Atoi(args[4])
	spd, err5 := strconv.Atoi(args[5])
	if err1 != nil || err2 != nil || err3 != nil || err4 != nil || err5 != nil {
		m.reply(controller, "Invalid SPAWN arguments")
		return
	}

	if m.find(callsign) != nil {
		m.reply(controller, "Callsign already exists: "+callsign)
		return
	}

	if _, err := m.spawn(controller.callsign, callsign, lat, lon, hdg, alt, spd); err != nil {
		m.reply(controller, "Could not spawn "+callsign+": "+err.Error())
		return
	}

	m.reply(controller, "Spawned "+callsign+" (you have the track)")
}

func (m *simManager) handleFixCommand(controller *Client, args []string) {
	// FIX <name> <lat> <lon>
	if len(args) < 3 {
		m.reply(controller, "Usage: FIX <name> <lat> <lon>")
		return
	}
	lat, err1 := strconv.ParseFloat(args[1], 64)
	lon, err2 := strconv.ParseFloat(args[2], 64)
	if err1 != nil || err2 != nil {
		m.reply(controller, "Invalid fix coordinates")
		return
	}
	m.defineFix(args[0], lat, lon)
	m.reply(controller, "Defined fix "+strings.ToUpper(args[0]))
}

// handleDirect implements `<cs> DCT <fix>` or `<cs> DCT <lat> <lon>`.
func (m *simManager) handleDirect(controller *Client, ac *simAircraft, args []string) {
	var wp waypoint
	switch {
	case len(args) >= 2:
		lat, err1 := strconv.ParseFloat(args[0], 64)
		lon, err2 := strconv.ParseFloat(args[1], 64)
		if err1 != nil || err2 != nil {
			m.reply(controller, "Invalid coordinates")
			return
		}
		wp = waypoint{Name: "DCT", Lat: lat, Lon: lon}
	case len(args) == 1:
		fix, ok := m.lookupFix(args[0])
		if !ok {
			m.reply(controller, "Unknown fix: "+strings.ToUpper(args[0]))
			return
		}
		wp = fix
	default:
		m.reply(controller, "Usage: <callsign> DCT <fix>|<lat> <lon>")
		return
	}

	ac.mu.Lock()
	ac.navMode = navLNAV
	ac.route = []waypoint{wp}
	ac.mu.Unlock()
	m.reply(controller, ac.callsign+" cleared direct "+wp.Name)
}

// handleRoute implements `<cs> ROUTE fix1 fix2[/alt] ...`.
func (m *simManager) handleRoute(controller *Client, ac *simAircraft, args []string) {
	if len(args) == 0 {
		m.reply(controller, "Usage: <callsign> ROUTE <fix>[/alt] ...")
		return
	}

	route := make([]waypoint, 0, len(args))
	for _, token := range args {
		name := token
		alt := 0
		if i := strings.IndexByte(token, '/'); i != -1 {
			name = token[:i]
			alt, _ = strconv.Atoi(token[i+1:])
		}
		fix, ok := m.lookupFix(name)
		if !ok {
			m.reply(controller, "Unknown fix: "+strings.ToUpper(name))
			return
		}
		fix.Alt = alt
		route = append(route, fix)
	}

	ac.mu.Lock()
	ac.navMode = navLNAV
	ac.route = route
	ac.mu.Unlock()
	m.reply(controller, fmt.Sprintf("%s cleared via %d fixes", ac.callsign, len(route)))
}

// reply sends a text message from the SIM pseudo-station to a controller.
func (m *simManager) reply(controller *Client, msg string) {
	controller.send("#TMSIM:" + controller.callsign + ":" + msg + "\r\n")
}

// buildPilotPositionPacket constructs an `@` pilot position packet for an aircraft.
func buildPilotPositionPacket(c *Client) string {
	ll := c.latLon()
	pbh := encodePitchBankHeading(0, 0, float64(c.heading.Load()))
	return fmt.Sprintf("@N:%s:%s:%d:%.5f:%.5f:%d:%d:%d:0\r\n",
		c.callsign,
		c.transponder.Load(),
		int(c.networkRating),
		ll[0], ll[1],
		c.altitude.Load(),
		c.groundspeed.Load(),
		pbh,
	)
}

// normalizeHeading wraps a heading into the [0, 360) range.
func normalizeHeading(h float64) float64 {
	h = math.Mod(h, 360)
	if h < 0 {
		h += 360
	}
	return h
}

// stepHeading moves current toward target by at most maxDelta degrees, taking the
// shortest turn direction, and wraps the result into [0, 360).
func stepHeading(current, target, maxDelta float64) float64 {
	diff := math.Mod(target-current+540, 360) - 180 // shortest signed difference
	if math.Abs(diff) <= maxDelta {
		return normalizeHeading(target)
	}
	if diff > 0 {
		return normalizeHeading(current + maxDelta)
	}
	return normalizeHeading(current - maxDelta)
}

// stepToward moves current toward target by at most maxDelta.
func stepToward(current, target, maxDelta float64) float64 {
	diff := target - current
	if math.Abs(diff) <= maxDelta {
		return target
	}
	if diff > 0 {
		return current + maxDelta
	}
	return current - maxDelta
}
