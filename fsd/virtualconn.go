package fsd

import (
	"io"
	"net"
	"sync"
	"time"
)

// virtualConn is a stub net.Conn used by server-side simulated aircraft.
//
// Simulated aircraft are not backed by a real network socket; their position is
// advanced by the simulation loop rather than by inbound packets. virtualConn
// allows such a Client to flow through all of the existing code paths (the post
// office, broadcasts, senderWorker, kill requests) without special-casing:
// outbound writes are discarded, and reads block until the connection is closed.
type virtualConn struct {
	done      chan struct{}
	closeOnce sync.Once
}

func newVirtualConn() *virtualConn {
	return &virtualConn{done: make(chan struct{})}
}

func (c *virtualConn) Read([]byte) (int, error) {
	<-c.done
	return 0, io.EOF
}

func (c *virtualConn) Write(b []byte) (int, error) {
	select {
	case <-c.done:
		return 0, io.ErrClosedPipe
	default:
		return len(b), nil // discard
	}
}

func (c *virtualConn) Close() error {
	c.closeOnce.Do(func() { close(c.done) })
	return nil
}

func (c *virtualConn) LocalAddr() net.Addr  { return &net.TCPAddr{IP: net.IPv4zero} }
func (c *virtualConn) RemoteAddr() net.Addr { return &net.TCPAddr{IP: net.IPv4zero} }

func (c *virtualConn) SetDeadline(time.Time) error      { return nil }
func (c *virtualConn) SetReadDeadline(time.Time) error  { return nil }
func (c *virtualConn) SetWriteDeadline(time.Time) error { return nil }
