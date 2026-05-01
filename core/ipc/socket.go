// Package ipc provides a Unix Domain Socket server for inter-process
// communication between the Flutter UI and the Go VPN core service.
//
// Security measures:
//   - Socket path is randomized (128-bit entropy) at each startup
//   - File permissions: chmod 0600 (owner-only access)
//   - UID verification: checks that connecting process has the same UID
//   - Message format: JSON-RPC 2.0
package ipc

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"sync"

	vpnlog "github.com/smokyw/firefly21/core/log"
	"golang.org/x/sys/unix"
)

// HandlerFunc processes a JSON-RPC request and returns a result or error.
type HandlerFunc func(ctx context.Context, params map[string]interface{}) (interface{}, error)

// ServerConfig holds the IPC server configuration.
type ServerConfig struct {
	// FilesDir is the application's private directory for the socket file.
	FilesDir string

	Logger *vpnlog.Logger
}

// Server is the Unix Domain Socket JSON-RPC server.
type Server struct {
	config     ServerConfig
	socketPath string
	listener   net.Listener
	handlers   map[string]HandlerFunc
	mu         sync.RWMutex
	cancel     context.CancelFunc
}

// jsonRPCRequest is a JSON-RPC 2.0 request message.
type jsonRPCRequest struct {
	JSONRPC string                 `json:"jsonrpc"`
	ID      interface{}            `json:"id"`
	Method  string                 `json:"method"`
	Params  map[string]interface{} `json:"params,omitempty"`
}

// jsonRPCResponse is a JSON-RPC 2.0 response message.
type jsonRPCResponse struct {
	JSONRPC string      `json:"jsonrpc"`
	ID      interface{} `json:"id"`
	Result  interface{} `json:"result,omitempty"`
	Error   *rpcError   `json:"error,omitempty"`
}

// rpcError represents a JSON-RPC 2.0 error object.
type rpcError struct {
	Code    int         `json:"code"`
	Message string      `json:"message"`
	Data    interface{} `json:"data,omitempty"`
}

// NewServer creates a new IPC server with a randomized socket path.
func NewServer(cfg ServerConfig) *Server {
	socketPath := generateSocketPath(cfg.FilesDir)
	return &Server{
		config:     cfg,
		socketPath: socketPath,
		handlers:   make(map[string]HandlerFunc),
	}
}

// SocketPath returns the full path to the Unix socket.
func (s *Server) SocketPath() string {
	return s.socketPath
}

// Handle registers a JSON-RPC method handler.
func (s *Server) Handle(method string, handler HandlerFunc) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.handlers[method] = handler
}

// Start begins listening for connections on the Unix socket.
func (s *Server) Start(ctx context.Context) error {
	// Remove stale socket file if it exists.
	os.Remove(s.socketPath)

	// Create the Unix domain socket listener.
	listener, err := net.Listen("unix", s.socketPath)
	if err != nil {
		return fmt.Errorf("listen on %s: %w", s.socketPath, err)
	}

	// Set restrictive permissions: owner-only read/write.
	if err := os.Chmod(s.socketPath, 0600); err != nil {
		listener.Close()
		return fmt.Errorf("chmod socket: %w", err)
	}

	childCtx, cancel := context.WithCancel(ctx)
	s.listener = listener
	s.cancel = cancel

	// Accept connections in the background.
	go s.acceptLoop(childCtx)

	return nil
}

// Stop closes the IPC server and cleans up the socket file.
func (s *Server) Stop() {
	if s.cancel != nil {
		s.cancel()
	}
	if s.listener != nil {
		s.listener.Close()
	}
	os.Remove(s.socketPath)
}

// acceptLoop processes incoming connections.
func (s *Server) acceptLoop(ctx context.Context) {
	defer s.listener.Close()

	for {
		select {
		case <-ctx.Done():
			return
		default:
		}

		conn, err := s.listener.Accept()
		if err != nil {
			if ctx.Err() != nil {
				return // Context cancelled, normal shutdown.
			}
			if s.config.Logger != nil {
				s.config.Logger.Error("ipc", "accept error", map[string]interface{}{
					"error": err.Error(),
				})
			}
			continue
		}

		// Verify the UID of the connecting process (security check).
		if err := s.verifyPeerUID(conn); err != nil {
			if s.config.Logger != nil {
				s.config.Logger.Warn("ipc", "rejected connection: UID mismatch", map[string]interface{}{
					"error": err.Error(),
				})
			}
			conn.Close()
			continue
		}

		go s.handleConnection(ctx, conn)
	}
}

// handleConnection processes a single client connection.
func (s *Server) handleConnection(ctx context.Context, conn net.Conn) {
	defer conn.Close()

	decoder := json.NewDecoder(conn)
	encoder := json.NewEncoder(conn)

	for {
		select {
		case <-ctx.Done():
			return
		default:
		}

		var req jsonRPCRequest
		if err := decoder.Decode(&req); err != nil {
			// Connection closed or invalid JSON — stop processing.
			return
		}

		// Validate JSON-RPC version.
		if req.JSONRPC != "2.0" {
			resp := jsonRPCResponse{
				JSONRPC: "2.0",
				ID:      req.ID,
				Error: &rpcError{
					Code:    -32600,
					Message: "Invalid Request: jsonrpc must be '2.0'",
				},
			}
			encoder.Encode(resp)
			continue
		}

		// Look up the handler for this method.
		s.mu.RLock()
		handler, ok := s.handlers[req.Method]
		s.mu.RUnlock()

		if !ok {
			resp := jsonRPCResponse{
				JSONRPC: "2.0",
				ID:      req.ID,
				Error: &rpcError{
					Code:    -32601,
					Message: fmt.Sprintf("Method not found: %s", req.Method),
				},
			}
			encoder.Encode(resp)
			continue
		}

		if s.config.Logger != nil {
			s.config.Logger.Debug("ipc", fmt.Sprintf("RPC call: %s", req.Method), nil)
		}

		// Execute the handler.
		result, err := handler(ctx, req.Params)
		var resp jsonRPCResponse
		if err != nil {
			resp = jsonRPCResponse{
				JSONRPC: "2.0",
				ID:      req.ID,
				Error: &rpcError{
					Code:    -32000,
					Message: err.Error(),
				},
			}
		} else {
			resp = jsonRPCResponse{
				JSONRPC: "2.0",
				ID:      req.ID,
				Result:  result,
			}
		}

		if err := encoder.Encode(resp); err != nil {
			if s.config.Logger != nil {
				s.config.Logger.Error("ipc", "encode response error", map[string]interface{}{
					"error": err.Error(),
				})
			}
			return
		}
	}
}

// verifyPeerUID checks that the connecting process has the same UID as this process.
// This prevents other apps on the device from connecting to the IPC socket.
func (s *Server) verifyPeerUID(conn net.Conn) error {
	unixConn, ok := conn.(*net.UnixConn)
	if !ok {
		return errors.New("not a Unix connection")
	}

	rawConn, err := unixConn.SyscallConn()
	if err != nil {
		return fmt.Errorf("get syscall conn: %w", err)
	}

	var cred *unix.Ucred
	var credErr error
	err = rawConn.Control(func(fd uintptr) {
		cred, credErr = unix.GetsockoptUcred(int(fd), unix.SOL_SOCKET, unix.SO_PEERCRED)
	})
	if err != nil {
		return fmt.Errorf("control: %w", err)
	}
	if credErr != nil {
		return fmt.Errorf("getsockopt peercred: %w", credErr)
	}

	myUID := uint32(os.Getuid())
	if cred.Uid != myUID {
		return fmt.Errorf("UID mismatch: peer=%d, self=%d", cred.Uid, myUID)
	}

	return nil
}

// generateSocketPath creates a randomized socket path with 128 bits of entropy.
func generateSocketPath(filesDir string) string {
	var buf [16]byte // 128 bits
	if _, err := rand.Read(buf[:]); err != nil {
		// Fallback to a less random but functional path.
		return filepath.Join(filesDir, "vpn_ipc.sock")
	}
	name := fmt.Sprintf("vpn_%s.sock", hex.EncodeToString(buf[:]))
	return filepath.Join(filesDir, name)
}
