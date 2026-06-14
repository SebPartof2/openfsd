package fsd

import (
	"context"
	"fmt"
	"math"
	"strconv"
	"strings"
	"sync"
	"time"
)

// simManager owns all server-side simulated aircraft.
//
// A simulated aircraft is an ordinary *Client (registered in the post office and
// visible to every controller) whose position is advanced by a flight model on a
// fixed timer instead of by inbound position packets. Aircraft persist
// independently of the controller who created them; maneuver authority follows
// the FSD track, i.e. whichever controller currently holds the track may issue
// commands.
type simManager struct {
	srv *Server
	ctx context.Context

	aircraft map[string]*Client // callsign -> simulated aircraft
	mu       sync.RWMutex

	nextCID int
}

const (
	simTickHz          = 4             // flight-model integration rate
	simBroadcastEveryN = 4             // broadcast a position every N ticks (~1 Hz)
	simTurnRate        = 3.0           // degrees per second (standard rate)
	simClimbRate       = 30.0          // feet per second (~1800 fpm)
	simAccelRate       = 5.0           // knots per second
	simDefaultVisRange = 50.0 * 1852.0 // meters (matches real pilot clients)
	simDefaultSquawk   = "2000"
)

func newSimManager(srv *Server) *simManager {
	return &simManager{
		srv:      srv,
		aircraft: make(map[string]*Client, 64),
		nextCID:  8000001,
	}
}

// find returns the simulated aircraft with the given callsign, or nil.
func (m *simManager) find(callsign string) *Client {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.aircraft[callsign]
}

// spawn creates a new simulated aircraft owned (tracked) by the given creator.
func (m *simManager) spawn(creator string, callsign string, lat, lon float64, hdg, alt, spd int) (*Client, error) {
	if !isValidClientCallsign([]byte(callsign)) {
		return nil, fmt.Errorf("invalid callsign")
	}

	m.mu.Lock()
	cid := m.nextCID
	m.nextCID++
	m.mu.Unlock()

	data := loginData{
		callsign:         callsign,
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
	c.creator = creator
	c.controllingController.Store(creator)
	c.transponder.Store(simDefaultSquawk)
	c.setLatLon(lat, lon)
	c.visRange.Store(simDefaultVisRange)
	c.heading.Store(int32(normalizeHeading(float64(hdg))))
	c.altitude.Store(int32(alt))
	c.groundspeed.Store(int32(spd))
	c.targetHeading.Store(int32(normalizeHeading(float64(hdg))))
	c.targetAltitude.Store(int32(alt))
	c.targetGroundspeed.Store(int32(spd))
	c.lastUpdated.Store(time.Now())

	if err := m.srv.postOffice.register(c); err != nil {
		return nil, err
	}

	m.mu.Lock()
	m.aircraft[callsign] = c
	m.mu.Unlock()

	// Drain the outbound channel (writes are discarded by the virtual conn) so
	// that broadcasts targeting this aircraft never block their sender.
	go c.senderWorker()

	// Announce the new aircraft to every connected client.
	m.srv.broadcastAddPacket(c)

	return c, nil
}

// remove deletes a simulated aircraft from the network.
func (m *simManager) remove(callsign string) bool {
	m.mu.Lock()
	c := m.aircraft[callsign]
	delete(m.aircraft, callsign)
	m.mu.Unlock()

	if c == nil {
		return false
	}

	m.srv.broadcastDisconnectPacket(c)
	m.srv.postOffice.release(c)
	c.cancelCtx()
	return true
}

// releaseTracksFor clears the track on any aircraft controlled by the given
// controller. Called when a controller disconnects: their aircraft remain on the
// network (continuing their last clearance) but become untracked, so that any
// other controller may take over.
func (m *simManager) releaseTracksFor(controller string) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	for _, c := range m.aircraft {
		if c.controllingController.Load() == controller {
			c.controllingController.Store("")
		}
	}
}

// setTrack records the controller currently holding an aircraft's track. Called
// when the server observes an Initiate Track (IT) or handoff acceptance (HT).
func (m *simManager) setTrack(callsign, controller string) {
	if c := m.find(callsign); c != nil {
		c.controllingController.Store(controller)
	}
}

// dropTrack clears an aircraft's track if it is currently held by controller.
func (m *simManager) dropTrack(callsign, controller string) {
	if c := m.find(callsign); c != nil {
		if c.controllingController.Load() == controller {
			c.controllingController.Store("")
		}
	}
}

// run executes the simulation loop until the context is cancelled.
func (m *simManager) run(ctx context.Context) {
	ticker := time.NewTicker(time.Second / simTickHz)
	defer ticker.Stop()

	last := time.Now()
	tick := 0

	for {
		select {
		case <-ctx.Done():
			return
		case now := <-ticker.C:
			dt := now.Sub(last).Seconds()
			last = now
			tick++
			broadcast := tick%simBroadcastEveryN == 0

			m.mu.RLock()
			snapshot := make([]*Client, 0, len(m.aircraft))
			for _, c := range m.aircraft {
				snapshot = append(snapshot, c)
			}
			m.mu.RUnlock()

			for _, c := range snapshot {
				m.step(c, dt, broadcast)
			}
		}
	}
}

// step advances a single aircraft's flight model by dt seconds and, when
// broadcast is true, transmits a position update to all in-range clients.
func (m *simManager) step(c *Client, dt float64, broadcast bool) {
	// Heading: turn toward the assigned heading at the standard rate.
	hdg := float64(c.heading.Load())
	tgtHdg := float64(c.targetHeading.Load())
	hdg = stepHeading(hdg, tgtHdg, simTurnRate*dt)
	c.heading.Store(int32(math.Round(hdg)))

	// Altitude: climb or descend toward the assigned altitude.
	alt := float64(c.altitude.Load())
	tgtAlt := float64(c.targetAltitude.Load())
	alt = stepToward(alt, tgtAlt, simClimbRate*dt)
	c.altitude.Store(int32(math.Round(alt)))

	// Groundspeed: accelerate or decelerate toward the assigned speed.
	gs := float64(c.groundspeed.Load())
	tgtGs := float64(c.targetGroundspeed.Load())
	gs = stepToward(gs, tgtGs, simAccelRate*dt)
	c.groundspeed.Store(int32(math.Round(gs)))

	// Position: dead-reckon along the current heading.
	if gs > 0 {
		ll := c.latLon()
		distNM := gs * dt / 3600.0
		hdgRad := hdg * degToRad
		newLat := ll[0] + (distNM/60.0)*math.Cos(hdgRad)
		cosLat := math.Cos(ll[0] * degToRad)
		newLon := ll[1]
		if cosLat != 0 {
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

// handleCommand parses and executes a controller's SIM command. Replies are sent
// back to the controller as text messages from the "SIM" pseudo-station.
func (m *simManager) handleCommand(controller *Client, body string) {
	fields := strings.Fields(body)
	if len(fields) == 0 {
		return
	}

	verb := strings.ToUpper(fields[0])

	if verb == "SPAWN" {
		m.handleSpawnCommand(controller, fields[1:])
		return
	}

	// All other commands operate on an existing aircraft: <callsign> <verb> [value]
	if len(fields) < 2 {
		m.reply(controller, "Usage: <callsign> <command> [value]")
		return
	}

	callsign := strings.ToUpper(fields[0])
	cmd := strings.ToUpper(fields[1])

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
	if len(fields) >= 3 {
		value = fields[2]
	}

	switch cmd {
	case "FH", "H", "HDG": // fly heading
		v, err := strconv.Atoi(value)
		if err != nil {
			m.reply(controller, "Invalid heading")
			return
		}
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
	case "SQ", "SQUAWK": // assign squawk code
		if value == "" {
			m.reply(controller, "Invalid squawk")
			return
		}
		ac.transponder.Store(value)
		m.reply(controller, callsign+" squawk "+value)
	case "DEL", "DELETE", "KILL":
		m.remove(callsign)
		m.reply(controller, callsign+" removed")
	default:
		m.reply(controller, "Unknown command: "+cmd)
	}
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
