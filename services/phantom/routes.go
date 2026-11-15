package main

import (
	"context"
	"errors"
	"slices"
	"sync"
	"time"
)

type request struct {
	node  string
	test  bool
	since time.Time
}
type routes struct {
	ctx       context.Context
	cancel    context.CancelFunc
	panel     *panel
	nodes     map[string]string
	gate      string
	port      int
	mu        sync.Mutex
	changed   chan struct{}
	queue     []*request
	active    string
	opening   int
	switching bool
	invalid   chan struct{}
}

func newRoutes(ctx context.Context, p *panel, n map[string]string, gate string, port int) *routes {
	child, cancel := context.WithCancel(ctx)
	return &routes{ctx: child, cancel: cancel, panel: p, nodes: n, gate: gate, port: port, changed: make(chan struct{}), invalid: make(chan struct{})}
}
func (r *routes) notify() { close(r.changed); r.changed = make(chan struct{}) }
func (r *routes) first() *request {
	if time.Since(r.queue[0].since) < 20*time.Second {
		for _, q := range r.queue {
			if !q.test {
				return q
			}
		}
	}
	return r.queue[0]
}
func (r *routes) selectNode(id string) error {
	var answer struct{ OK *bool }
	data := map[string]string{"id": id, "mode": "global"}
	err := r.panel.call(r.ctx, "connect", data, &answer)
	var api *apiError
	if errors.As(err, &api) && api.code == 401 {
		if err = r.panel.login(r.ctx, "unlock", map[string]string{"admin_password": r.gate}); err == nil {
			err = r.panel.call(r.ctx, "connect", data, &answer)
		}
	}
	if err == nil && answer.OK != nil && !*answer.OK {
		return errors.New("vendor rejected route")
	}
	return err
}
func (r *routes) admit(ctx context.Context, node string, test bool) error {
	q := &request{node: node, test: test, since: time.Now()}
	r.mu.Lock()
	r.queue = append(r.queue, q)
	defer func() {
		i := slices.Index(r.queue, q)
		r.queue = slices.Delete(r.queue, i, i+1)
		r.notify()
		r.mu.Unlock()
	}()
	for ctx.Err() == nil && r.ctx.Err() == nil {
		if !r.switching && r.first().node == node {
			if r.active == node {
				r.opening++
				return nil
			}
			if r.opening == 0 {
				r.switching = true
				r.mu.Unlock()
				err := r.selectNode(node)
				r.mu.Lock()
				r.switching = false
				r.notify()
				if err != nil {
					r.active = ""
					// A lost response may mean the library switched routes. Stop all admissions
					// until the official engine has been restarted and authenticated again.
					var api *apiError
					if !errors.As(err, &api) {
						r.cancel()
						close(r.invalid)
					}
					return err
				}
				r.active = node
				continue
			}
		}
		wake := r.changed
		r.mu.Unlock()
		select {
		case <-wake:
		case <-ctx.Done():
		case <-r.ctx.Done():
		}
		r.mu.Lock()
	}
	return context.Canceled
}
func (r *routes) pinned() { r.mu.Lock(); r.opening--; r.notify(); r.mu.Unlock() }
