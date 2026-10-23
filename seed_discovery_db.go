package main

import (
	"fmt"
	"os"
	"time"

	"github.com/ethereum/go-ethereum/p2p/enode"
)

func main() {
	if len(os.Args) < 3 {
		fmt.Fprintln(os.Stderr, "usage: seed_discovery_db <database-path> <enode-url>...")
		os.Exit(2)
	}
	if err := seed(os.Args[1], os.Args[2:]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func seed(path string, urls []string) error {
	db, err := enode.OpenDB(path)
	if err != nil {
		return fmt.Errorf("open node database: %w", err)
	}
	defer db.Close()

	want := make(map[enode.ID]struct{}, len(urls))
	seedTime := time.Now()
	for _, raw := range urls {
		node, err := enode.ParseV4(raw)
		if err != nil {
			return fmt.Errorf("parse %q: %w", raw, err)
		}
		if !node.IPAddr().IsValid() || node.TCP() == 0 || node.UDP() == 0 {
			return fmt.Errorf("node %s has an incomplete endpoint", node.ID())
		}
		if _, exists := want[node.ID()]; exists {
			return fmt.Errorf("duplicate node ID %s", node.ID())
		}
		want[node.ID()] = struct{}{}
		if err := db.UpdateNode(node); err != nil {
			return fmt.Errorf("store node %s: %w", node.ID(), err)
		}
		if err := db.UpdateLastPongReceived(node.ID(), node.IPAddr(), seedTime); err != nil {
			return fmt.Errorf("mark node %s as a recent seed: %w", node.ID(), err)
		}
	}

	seeds := db.QuerySeeds(len(urls), 5*24*time.Hour)
	for id := range want {
		node := db.Node(id)
		if node == nil {
			return fmt.Errorf("node database omitted seed %s", id)
		}
		lastPong := db.LastPongReceived(id, node.IPAddr())
		if time.Since(lastPong) > 5*24*time.Hour {
			return fmt.Errorf("seed %s has stale last-pong time %s", id, lastPong)
		}
	}
	fmt.Printf("verified %d discovery DB records; first QuerySeeds sample returned %d\n", len(want), len(seeds))
	return nil
}
