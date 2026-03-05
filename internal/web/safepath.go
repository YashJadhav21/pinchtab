package web

import (
	"fmt"
	"path/filepath"
	"strings"
)

// SafePath validates that the resolved path stays within the allowed base directory.
// Returns the cleaned absolute path or an error if traversal is detected.
func SafePath(base, userPath string) (string, error) {
	absBase, err := filepath.Abs(base)
	if err != nil {
		return "", fmt.Errorf("invalid base path: %w", err)
	}

	// Detect absolute paths. On Windows filepath.IsAbs("/etc/passwd") returns
	// false because it lacks a drive letter, but the leading separator makes it
	// root-relative (resolves to <current-drive>:\etc\passwd). We must treat
	// any path that starts with a separator as absolute to prevent it from
	// being silently joined into the base directory.
	isAbs := filepath.IsAbs(userPath) ||
		strings.HasPrefix(userPath, "/") ||
		strings.HasPrefix(userPath, string(filepath.Separator))

	var resolved string
	if isAbs {
		// Resolve via filepath.Abs so root-relative paths like "/etc/passwd"
		// get a drive letter on Windows (e.g. "C:\etc\passwd"), making the
		// prefix check below work correctly on every platform.
		resolved, err = filepath.Abs(filepath.Clean(userPath))
		if err != nil {
			return "", fmt.Errorf("invalid user path: %w", err)
		}
	} else {
		resolved = filepath.Clean(filepath.Join(absBase, userPath))
	}

	// Ensure resolved path is within or equal to base.
	resolved, err = filepath.Abs(resolved)
	if err != nil {
		return "", fmt.Errorf("invalid resolved path: %w", err)
	}

	// Ensure resolved path is within or equal to base
	if !strings.HasPrefix(resolved, absBase+string(filepath.Separator)) && resolved != absBase {
		return "", fmt.Errorf("path %q escapes base directory %q", userPath, absBase)
	}

	return resolved, nil
}
