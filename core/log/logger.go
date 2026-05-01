// Package log provides unified structured logging for all VPN core components.
// Log entries use JSON format with consistent fields:
//
//	{timestamp, level, source, message, context?}
//
// Features:
//   - File rotation (lumberjack): max 5 files x 10 MB each
//   - Real-time streaming to Flutter UI via IPC
//   - In-memory ring buffer for recent entries
//   - Automatic redaction of sensitive data (keys, tokens, passwords)
//   - Source tagging for component identification (xray, arti, hev, vpn, ipc)
package log

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
)

// Log levels.
const (
	LevelTrace = "trace"
	LevelDebug = "debug"
	LevelInfo  = "info"
	LevelWarn  = "warn"
	LevelError = "error"
)

// levelPriority maps level strings to numeric priority for filtering.
var levelPriority = map[string]int{
	LevelTrace: 0,
	LevelDebug: 1,
	LevelInfo:  2,
	LevelWarn:  3,
	LevelError: 4,
}

// Config holds the logger configuration.
type Config struct {
	// Level is the minimum log level to record.
	Level string

	// MaxSizeMB is the maximum size per log file in megabytes.
	MaxSizeMB int

	// MaxFiles is the maximum number of rotated log files to keep.
	MaxFiles int

	// OutputDir is the directory for log files.
	OutputDir string

	// JSONFormat enables JSON output (always true for production).
	JSONFormat bool
}

// Entry is a single log entry in the unified format.
type Entry struct {
	Timestamp string                 `json:"timestamp"`
	Level     string                 `json:"level"`
	Source    string                 `json:"source"`
	Message   string                 `json:"message"`
	Context   map[string]interface{} `json:"context,omitempty"`
}

// Logger is the unified structured logger.
type Logger struct {
	config     Config
	file       *os.File
	filePath   string
	fileSize   int64
	fileIndex  int
	mu         sync.Mutex
	ring       []Entry
	ringIdx    int
	ringFull   bool
	ringSize   int
	listeners  []chan Entry
	listenerMu sync.RWMutex
	minLevel   int
}

const defaultRingSize = 1000

// NewLogger creates a new Logger with the given configuration.
func NewLogger(cfg Config) *Logger {
	if cfg.MaxSizeMB <= 0 {
		cfg.MaxSizeMB = 10
	}
	if cfg.MaxFiles <= 0 {
		cfg.MaxFiles = 5
	}

	l := &Logger{
		config:   cfg,
		ring:     make([]Entry, defaultRingSize),
		ringSize: defaultRingSize,
		minLevel: levelPriority[cfg.Level],
	}

	// Open the initial log file.
	if cfg.OutputDir != "" {
		os.MkdirAll(cfg.OutputDir, 0700)
		l.rotateFile()
	}

	return l
}

// Close shuts down the logger and flushes all pending entries.
func (l *Logger) Close() {
	l.mu.Lock()
	defer l.mu.Unlock()

	if l.file != nil {
		l.file.Close()
		l.file = nil
	}

	l.listenerMu.Lock()
	for _, ch := range l.listeners {
		close(ch)
	}
	l.listeners = nil
	l.listenerMu.Unlock()
}

// Trace logs at trace level.
func (l *Logger) Trace(source, message string, ctx map[string]interface{}) {
	l.log(LevelTrace, source, message, ctx)
}

// Debug logs at debug level.
func (l *Logger) Debug(source, message string, ctx map[string]interface{}) {
	l.log(LevelDebug, source, message, ctx)
}

// Info logs at info level.
func (l *Logger) Info(source, message string, ctx map[string]interface{}) {
	l.log(LevelInfo, source, message, ctx)
}

// Warn logs at warn level.
func (l *Logger) Warn(source, message string, ctx map[string]interface{}) {
	l.log(LevelWarn, source, message, ctx)
}

// Error logs at error level.
func (l *Logger) Error(source, message string, ctx map[string]interface{}) {
	l.log(LevelError, source, message, ctx)
}

// Subscribe returns a channel that receives all log entries in real time.
// Used by the IPC layer to stream logs to the Flutter UI.
func (l *Logger) Subscribe() chan Entry {
	ch := make(chan Entry, 256) // Buffered to prevent backpressure blocking.
	l.listenerMu.Lock()
	l.listeners = append(l.listeners, ch)
	l.listenerMu.Unlock()
	return ch
}

// Unsubscribe removes a listener channel.
func (l *Logger) Unsubscribe(ch chan Entry) {
	l.listenerMu.Lock()
	defer l.listenerMu.Unlock()

	for i, listener := range l.listeners {
		if listener == ch {
			l.listeners = append(l.listeners[:i], l.listeners[i+1:]...)
			close(ch)
			return
		}
	}
}

// RecentEntries returns the last n log entries from the ring buffer.
func (l *Logger) RecentEntries(n int) []Entry {
	l.mu.Lock()
	defer l.mu.Unlock()

	total := l.ringIdx
	if l.ringFull {
		total = l.ringSize
	}
	if n > total {
		n = total
	}
	if n <= 0 {
		return nil
	}

	result := make([]Entry, n)
	start := l.ringIdx - n
	if start < 0 {
		if l.ringFull {
			start += l.ringSize
		} else {
			start = 0
			n = l.ringIdx
			result = make([]Entry, n)
		}
	}

	for i := 0; i < n; i++ {
		idx := (start + i) % l.ringSize
		result[i] = l.ring[idx]
	}

	return result
}

// log creates and dispatches a log entry.
func (l *Logger) log(level, source, message string, ctx map[string]interface{}) {
	pri, ok := levelPriority[level]
	if !ok {
		pri = 2
	}
	if pri < l.minLevel {
		return
	}

	entry := Entry{
		Timestamp: time.Now().UTC().Format("2006-01-02T15:04:05.000Z"),
		Level:     level,
		Source:    source,
		Message:   redactSensitive(message),
		Context:   redactContext(ctx),
	}

	// Write to ring buffer.
	l.mu.Lock()
	l.ring[l.ringIdx] = entry
	l.ringIdx = (l.ringIdx + 1) % l.ringSize
	if l.ringIdx == 0 {
		l.ringFull = true
	}

	// Write to file.
	if l.file != nil {
		data, err := json.Marshal(entry)
		if err == nil {
			data = append(data, '\n')
			n, _ := l.file.Write(data)
			l.fileSize += int64(n)

			// Check if rotation is needed.
			if l.fileSize >= int64(l.config.MaxSizeMB)*1024*1024 {
				l.rotateFile()
			}
		}
	}
	l.mu.Unlock()

	// Notify subscribers (non-blocking with backpressure drop).
	l.listenerMu.RLock()
	for _, ch := range l.listeners {
		select {
		case ch <- entry:
		default:
			// Drop entry if subscriber buffer is full (backpressure control).
		}
	}
	l.listenerMu.RUnlock()
}

// rotateFile closes the current log file and opens a new one.
// Must be called with l.mu held.
func (l *Logger) rotateFile() {
	if l.file != nil {
		l.file.Close()
	}

	l.fileIndex++
	if l.fileIndex > l.config.MaxFiles {
		l.fileIndex = 1
	}

	filename := fmt.Sprintf("vpn_core_%d.log", l.fileIndex)
	path := filepath.Join(l.config.OutputDir, filename)

	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0600)
	if err != nil {
		l.file = nil
		return
	}

	l.file = f
	l.filePath = path
	l.fileSize = 0
}

// Sensitive data patterns for automatic redaction.
var sensitivePatterns = []*regexp.Regexp{
	regexp.MustCompile(`(?i)(password|passwd|pwd)\s*[=:]\s*\S+`),
	regexp.MustCompile(`(?i)(token|api[_-]?key|secret|auth)\s*[=:]\s*\S+`),
	regexp.MustCompile(`(?i)(private[_-]?key)\s*[=:]\s*\S+`),
	regexp.MustCompile(`[0-9a-fA-F]{32,}`), // Long hex strings (potential keys/hashes).
	regexp.MustCompile(`(?i)bearer\s+\S+`),
}

// redactSensitive removes sensitive information from log messages.
func redactSensitive(msg string) string {
	for _, re := range sensitivePatterns {
		msg = re.ReplaceAllStringFunc(msg, func(match string) string {
			// Keep the first few characters for debugging, redact the rest.
			if len(match) > 12 {
				return match[:8] + "[REDACTED]"
			}
			return "[REDACTED]"
		})
	}
	return msg
}

// redactContext removes sensitive values from context maps.
func redactContext(ctx map[string]interface{}) map[string]interface{} {
	if ctx == nil {
		return nil
	}

	result := make(map[string]interface{}, len(ctx))
	for k, v := range ctx {
		key := strings.ToLower(k)
		if strings.Contains(key, "password") ||
			strings.Contains(key, "secret") ||
			strings.Contains(key, "token") ||
			strings.Contains(key, "key") ||
			strings.Contains(key, "auth") {
			result[k] = "[REDACTED]"
		} else if s, ok := v.(string); ok {
			result[k] = redactSensitive(s)
		} else {
			result[k] = v
		}
	}
	return result
}

// ExportLogs writes all recent log entries to an export file.
// Returns the path to the exported file.
func (l *Logger) ExportLogs(outputDir string) (string, error) {
	entries := l.RecentEntries(l.ringSize)
	if len(entries) == 0 {
		return "", fmt.Errorf("no log entries to export")
	}

	timestamp := time.Now().Format("20060102_150405")
	filename := fmt.Sprintf("vpn_export_%s.log", timestamp)
	path := filepath.Join(outputDir, "logs", filename)

	os.MkdirAll(filepath.Dir(path), 0700)

	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0600)
	if err != nil {
		return "", fmt.Errorf("create export file: %w", err)
	}
	defer f.Close()

	encoder := json.NewEncoder(f)
	for _, entry := range entries {
		if err := encoder.Encode(entry); err != nil {
			return "", fmt.Errorf("write entry: %w", err)
		}
	}

	return path, nil
}
