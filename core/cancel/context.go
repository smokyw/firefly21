// Package cancel provides centralized context management for all VPN
// subsystems. Each named subsystem (xray, arti, hev, vpn) gets its own
// cancellable context derived from a root context. This enables:
//   - Individual subsystem shutdown (e.g., reconnect Arti without stopping xray)
//   - Global shutdown via root context cancellation
//   - Active subsystem tracking for status reporting
package cancel

import (
	"context"
	"sync"
)

// Manager coordinates cancellation across all VPN subsystems.
type Manager struct {
	rootCtx    context.Context
	rootCancel context.CancelFunc
	children   map[string]*child
	mu         sync.Mutex
}

type child struct {
	ctx    context.Context
	cancel context.CancelFunc
}

// NewManager creates a new cancellation manager with a fresh root context.
func NewManager() *Manager {
	ctx, cancel := context.WithCancel(context.Background())
	return &Manager{
		rootCtx:    ctx,
		rootCancel: cancel,
		children:   make(map[string]*child),
	}
}

// RootContext returns the root context. When this is cancelled, all child
// contexts are also cancelled.
func (m *Manager) RootContext() context.Context {
	return m.rootCtx
}

// NewContext creates a named child context derived from the root.
// If a context with the same name already exists, it is cancelled first.
// The returned context is cancelled when either:
//   - Cancel(name) is called
//   - CancelAll() is called
//   - The root context is cancelled
func (m *Manager) NewContext(name string) context.Context {
	m.mu.Lock()
	defer m.mu.Unlock()

	// Cancel existing context with this name, if any.
	if existing, ok := m.children[name]; ok {
		existing.cancel()
	}

	ctx, cancel := context.WithCancel(m.rootCtx)
	m.children[name] = &child{
		ctx:    ctx,
		cancel: cancel,
	}

	return ctx
}

// Cancel cancels the named child context and removes it from tracking.
func (m *Manager) Cancel(name string) {
	m.mu.Lock()
	defer m.mu.Unlock()

	if c, ok := m.children[name]; ok {
		c.cancel()
		delete(m.children, name)
	}
}

// CancelAll cancels all child contexts and the root context.
// After this call, no new contexts can be created.
func (m *Manager) CancelAll() {
	m.mu.Lock()
	defer m.mu.Unlock()

	for name, c := range m.children {
		c.cancel()
		delete(m.children, name)
	}
	m.rootCancel()
}

// IsActive returns true if the named context is still active (not cancelled).
func (m *Manager) IsActive(name string) bool {
	m.mu.Lock()
	defer m.mu.Unlock()

	c, ok := m.children[name]
	if !ok {
		return false
	}
	return c.ctx.Err() == nil
}

// ActiveNames returns the names of all active (non-cancelled) child contexts.
func (m *Manager) ActiveNames() []string {
	m.mu.Lock()
	defer m.mu.Unlock()

	var names []string
	for name, c := range m.children {
		if c.ctx.Err() == nil {
			names = append(names, name)
		}
	}
	return names
}

// GetContext returns the context for the named subsystem, or nil if not found.
func (m *Manager) GetContext(name string) context.Context {
	m.mu.Lock()
	defer m.mu.Unlock()

	if c, ok := m.children[name]; ok {
		return c.ctx
	}
	return nil
}
