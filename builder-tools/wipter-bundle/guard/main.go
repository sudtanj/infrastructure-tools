// wipter-guard: proxyrack-bundle's guard (keep the two in sync) plus -local:
// a SOCKS5 front for tailscaled's SOCKS5 server. graftcp sends every TCP
// connection of the Wipter app here; only public IPv4 destinations are passed
// on (so through the exit node), and the loopback addresses given with -local
// are dialed directly (the app's own SOCKS5 server, which its wipter-tunnel
// process connects to). Private and reserved
// ranges, the tailnet, loopback, IPv6 and mail/DoT ports are refused, and port
// 53 always goes to the configured DNS server. UDP ASSOCIATE is refused, so
// with graftcp's only_socks5 mode the client's UDP is dropped, never sent
// directly. Nothing is logged per connection.
package main

import (
	"encoding/binary"
	"errors"
	"flag"
	"io"
	"log"
	"net"
	"net/netip"
	"strings"
	"time"
)

var (
	listen   = flag.String("listen", "127.0.0.1:1081", "address to listen on")
	upstream = flag.String("upstream", "127.0.0.1:1055", "tailscaled SOCKS5 server")
	dns      = flag.String("dns", "94.140.14.15:53", "where every port-53 connection goes")
	local    = flag.String("local", "", "comma-separated loopback ip:port dialed directly, nothing else local")
)

var localAddrs = map[netip.AddrPort]bool{}

var blocked = []netip.Prefix{
	netip.MustParsePrefix("0.0.0.0/8"),
	netip.MustParsePrefix("100.64.0.0/10"), // CGNAT, includes the tailnet
	netip.MustParsePrefix("192.0.0.0/24"),
	netip.MustParsePrefix("192.0.2.0/24"),
	netip.MustParsePrefix("198.18.0.0/15"),
	netip.MustParsePrefix("198.51.100.0/24"),
	netip.MustParsePrefix("203.0.113.0/24"),
	netip.MustParsePrefix("240.0.0.0/4"),
}

var blockedPorts = map[uint16]bool{25: true, 465: true, 587: true, 853: true}

// SOCKS5 reply codes.
const (
	repOK          = 0
	repNotAllowed  = 2
	repCmdNotSupp  = 7
	repAddrNotSupp = 8
)

func allowed(ip netip.Addr, port uint16) bool {
	if !ip.Is4() || !ip.IsGlobalUnicast() || ip.IsPrivate() || blockedPorts[port] {
		return false
	}
	for _, p := range blocked {
		if p.Contains(ip) {
			return false
		}
	}
	return true
}

func main() {
	flag.Parse()
	dnsAddr, err := netip.ParseAddrPort(*dns)
	if err != nil {
		log.Fatalf("bad -dns: %v", err)
	}
	for _, a := range strings.Split(*local, ",") {
		if a = strings.TrimSpace(a); a == "" {
			continue
		}
		ap, err := netip.ParseAddrPort(a)
		if err != nil || !ap.Addr().Is4() || !ap.Addr().IsLoopback() {
			log.Fatalf("bad -local %q: an IPv4 loopback ip:port", a)
		}
		localAddrs[ap] = true
	}
	ln, err := net.Listen("tcp", *listen)
	if err != nil {
		log.Fatal(err)
	}
	log.Printf("listening on %s", *listen)
	for {
		c, err := ln.Accept()
		if err != nil {
			log.Fatal(err)
		}
		go serve(c, dnsAddr)
	}
}

func reply(c net.Conn, code byte) {
	c.Write([]byte{5, code, 0, 1, 0, 0, 0, 0, 0, 0})
}

func serve(c net.Conn, dnsAddr netip.AddrPort) {
	defer c.Close()
	c.SetDeadline(time.Now().Add(30 * time.Second))
	dst, code := handshake(c)
	if code != repOK {
		reply(c, code)
		return
	}
	var up net.Conn
	if localAddrs[dst] {
		u, err := net.DialTimeout("tcp", dst.String(), 10*time.Second)
		if err != nil {
			reply(c, 5) // connection refused
			return
		}
		up, code = u, repOK
	} else {
		if dst.Port() == 53 {
			dst = dnsAddr
		} else if !allowed(dst.Addr(), dst.Port()) {
			reply(c, repNotAllowed)
			return
		}
		up, code = dialUpstream(dst)
	}
	if code != repOK {
		reply(c, code)
		return
	}
	defer up.Close()
	reply(c, repOK)
	c.SetDeadline(time.Time{})
	up.SetDeadline(time.Time{})
	done := make(chan struct{}, 2)
	pipe := func(dst, src net.Conn) {
		io.Copy(dst, src)
		if t, ok := dst.(*net.TCPConn); ok {
			t.CloseWrite()
		}
		done <- struct{}{}
	}
	go pipe(up, c)
	go pipe(c, up)
	<-done
	<-done
}

// handshake reads the greeting and the request; only no-auth CONNECT to an
// IPv4 address is accepted (graftcp only knows the IP the client connected to).
func handshake(c net.Conn) (netip.AddrPort, byte) {
	var none netip.AddrPort
	h := make([]byte, 2)
	if _, err := io.ReadFull(c, h); err != nil || h[0] != 5 {
		return none, repNotAllowed
	}
	methods := make([]byte, h[1])
	if _, err := io.ReadFull(c, methods); err != nil {
		return none, repNotAllowed
	}
	if _, err := c.Write([]byte{5, 0}); err != nil {
		return none, repNotAllowed
	}
	req := make([]byte, 4)
	if _, err := io.ReadFull(c, req); err != nil || req[0] != 5 {
		return none, repNotAllowed
	}
	if req[1] != 1 {
		return none, repCmdNotSupp
	}
	if req[3] != 1 {
		return none, repAddrNotSupp
	}
	a := make([]byte, 6)
	if _, err := io.ReadFull(c, a); err != nil {
		return none, repNotAllowed
	}
	return netip.AddrPortFrom(netip.AddrFrom4([4]byte(a[:4])), binary.BigEndian.Uint16(a[4:])), repOK
}

func dialUpstream(dst netip.AddrPort) (net.Conn, byte) {
	up, err := net.DialTimeout("tcp", *upstream, 10*time.Second)
	if err != nil {
		return nil, 1
	}
	up.SetDeadline(time.Now().Add(30 * time.Second))
	code, err := upstreamConnect(up, dst)
	if err != nil || code != repOK {
		up.Close()
		if code == repOK {
			code = 1
		}
		return nil, code
	}
	return up, repOK
}

func upstreamConnect(up net.Conn, dst netip.AddrPort) (byte, error) {
	if _, err := up.Write([]byte{5, 1, 0}); err != nil {
		return 1, err
	}
	m := make([]byte, 2)
	if _, err := io.ReadFull(up, m); err != nil || m[1] != 0 {
		return 1, errors.New("upstream refused no-auth")
	}
	ip := dst.Addr().As4()
	req := append([]byte{5, 1, 0, 1}, ip[:]...)
	req = binary.BigEndian.AppendUint16(req, dst.Port())
	if _, err := up.Write(req); err != nil {
		return 1, err
	}
	r := make([]byte, 4)
	if _, err := io.ReadFull(up, r); err != nil {
		return 1, err
	}
	var n int
	switch r[3] {
	case 1:
		n = 4
	case 4:
		n = 16
	case 3:
		l := make([]byte, 1)
		if _, err := io.ReadFull(up, l); err != nil {
			return 1, err
		}
		n = int(l[0])
	default:
		return 1, errors.New("bad upstream reply")
	}
	if _, err := io.ReadFull(up, make([]byte, n+2)); err != nil {
		return 1, err
	}
	return r[1], nil
}
