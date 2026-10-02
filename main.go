// Licenseware Collector installer for Windows.
// Downloads, verifies, installs, and registers the collector binary.
package main

import (
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"time"
)

const (
	cdnBaseURL       = "https://cdn.licenseware-collector.com"
	binaryName       = "LicensewareCollector.exe"
	downloadFilename = "LicensewareCollector.exe"
	installationDir  = ".licenseware-collector"
	downloadTimeout  = 5 * time.Minute
	checksumTimeout  = 30 * time.Second
	shutdownTimeout  = 10 * time.Second
)

var (
	installDir string
	logDir     string
	tempDir    string

	Version string
)

func main() {
	token := flag.String("t", os.Getenv("TOKEN"), "Registration token for the collector")
	flag.StringVar(token, "token", os.Getenv("TOKEN"), "Registration token for the collector")
	cleanupOnFailure := flag.Bool("cleanup-on-failure", os.Getenv("CLEANUP_ON_FAILURE") != "false", "Clean up temp directory on failure")
	flag.Parse()

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	done := make(chan error, 1)
	go func() {
		done <- run(ctx, *token, *cleanupOnFailure)
	}()

	select {
	case err := <-done:
		if err != nil {
			logMessage("ERROR", "Installation failed: %v", err)
			os.Exit(1)
		}
	case sig := <-ctx.Done():
		logMessage("INFO", "Received signal %v, initiating graceful shutdown...", sig)
		stop()

		shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), shutdownTimeout)
		defer shutdownCancel()

		select {
		case err := <-done:
			if err != nil {
				logMessage("ERROR", "Installation failed during shutdown: %v", err)
				os.Exit(1)
			}
		case <-shutdownCtx.Done():
			logMessage("ERROR", "Shutdown timeout exceeded, forcing exit")
			os.Exit(130)
		}
	}
}

func run(ctx context.Context, token string, cleanupOnFailure bool) error {
	homeDir, err := os.UserHomeDir()
	if err != nil {
		return fmt.Errorf("failed to get user home directory: %w", err)
	}

	logDir = filepath.Join(homeDir, installationDir)
	installDir = filepath.Join(logDir, "bin")

	logMessage("INFO", "========== Licenseware Collector Installation Started ==========")
	logMessage("INFO", "Timestamp: %s", time.Now().Format(time.RFC3339))
	logMessage("INFO", "User: %s", os.Getenv("USERNAME"))
	logMessage("INFO", "Installer Version: %s", Version)
	logMessage("INFO", "Go Version: %s", runtime.Version())
	logMessage("INFO", "OS: %s/%s", runtime.GOOS, runtime.GOARCH)

	var installErr error
	defer func() {
		if installErr != nil && cleanupOnFailure {
			removeTempDir()
		} else if installErr != nil {
			logMessage("INFO", "Temporary directory preserved for debugging: %s", tempDir)
		} else {
			removeTempDir()
		}
	}()

	if installErr = validateArchitecture(); installErr != nil {
		return installErr
	}

	select {
	case <-ctx.Done():
		installErr = ctx.Err()
		return fmt.Errorf("installation cancelled: %w", ctx.Err())
	default:
	}

	if installErr = createTempDir(); installErr != nil {
		return installErr
	}

	checksumsPath, err := downloadChecksums(ctx)
	if err != nil {
		installErr = err
		return err
	}

	binaryPath, err := downloadBinary(ctx)
	if err != nil {
		installErr = err
		return err
	}

	if err := validateChecksum(ctx, binaryPath, checksumsPath); err != nil {
		installErr = err
		return err
	}

	if err := installBinary(ctx, binaryPath); err != nil {
		installErr = err
		return err
	}

	if err := updatePath(ctx); err != nil {
		installErr = err
		return err
	}

	if err := registerCollector(ctx, token); err != nil {
		installErr = err
		return err
	}

	logMessage("INFO", "========== Installation Completed Successfully ==========")
	logMessage("INFO", "Binary installed to: %s", filepath.Join(installDir, binaryName))

	return nil
}

func logMessage(level, format string, args ...any) {
	timestamp := time.Now().Format("2006-01-02T15:04:05")
	prefix := ""
	if level == "ERROR" {
		prefix = "ERROR: "
	}
	message := fmt.Sprintf(format, args...)
	entry := fmt.Sprintf("[%s] %s%s", timestamp, prefix, message)

	if level == "ERROR" {
		fmt.Fprintln(os.Stderr, entry)
	} else {
		fmt.Println(entry)
	}
}

func validateArchitecture() error {
	logMessage("INFO", "Validating system architecture...")

	if runtime.GOOS != "windows" {
		logMessage("ERROR", "Unsupported operating system: %s", runtime.GOOS)
		return fmt.Errorf("only Windows is supported, got: %s", runtime.GOOS)
	}

	if runtime.GOARCH != "amd64" {
		logMessage("ERROR", "Unsupported architecture: %s", runtime.GOARCH)
		return fmt.Errorf("only AMD64 architecture is supported, got: %s", runtime.GOARCH)
	}

	logMessage("INFO", "[OK] Architecture validated: Windows amd64")
	return nil
}

func createTempDir() error {
	dir, err := os.MkdirTemp("", "licenseware-install-*")
	if err != nil {
		return fmt.Errorf("failed to create temp directory: %w", err)
	}
	tempDir = dir
	logMessage("INFO", "Created temporary directory: %s", tempDir)
	return nil
}

func removeTempDir() {
	if tempDir == "" {
		return
	}
	if _, err := os.Stat(tempDir); os.IsNotExist(err) {
		return
	}
	logMessage("INFO", "Cleaning up temporary directory: %s", tempDir)
	if err := os.RemoveAll(tempDir); err != nil {
		logMessage("ERROR", "Failed to remove temp directory: %v", err)
	}
}

func downloadChecksums(ctx context.Context) (string, error) {
	logMessage("INFO", "Downloading checksums from CDN...")

	url := cdnBaseURL + "/checksums.txt"
	destPath := filepath.Join(tempDir, "checksums.txt")

	if err := downloadFile(ctx, url, destPath, checksumTimeout); err != nil {
		logMessage("ERROR", "Failed to download checksums from %s: %v", url, err)
		return "", err
	}

	logMessage("INFO", "[OK] Checksums downloaded successfully")
	return destPath, nil
}

func downloadBinary(ctx context.Context) (string, error) {
	logMessage("INFO", "Downloading %s from CDN...", downloadFilename)

	url := cdnBaseURL + "/" + downloadFilename
	destPath := filepath.Join(tempDir, downloadFilename)

	if err := downloadFile(ctx, url, destPath, downloadTimeout); err != nil {
		logMessage("ERROR", "Failed to download %s: %v", downloadFilename, err)
		return "", err
	}

	info, err := os.Stat(destPath)
	if err != nil {
		return "", fmt.Errorf("downloaded file not found: %w", err)
	}

	sizeMB := float64(info.Size()) / (1024 * 1024)
	logMessage("INFO", "[OK] Downloaded %s (%.2f MB)", downloadFilename, sizeMB)

	return destPath, nil
}

func downloadFile(ctx context.Context, url, destPath string, timeout time.Duration) error {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return fmt.Errorf("failed to create request: %w", err)
	}

	client := &http.Client{}
	resp, err := client.Do(req)
	if err != nil {
		if ctx.Err() == context.Canceled {
			return fmt.Errorf("download cancelled: %w", ctx.Err())
		}
		if ctx.Err() == context.DeadlineExceeded {
			return fmt.Errorf("download timeout: %w", ctx.Err())
		}
		return fmt.Errorf("HTTP request failed: %w", err)
	}
	defer func() {
		if err := resp.Body.Close(); err != nil {
			logMessage("ERROR", "Failed to close response body: %v", err)
		}
	}()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("unexpected status code: %d", resp.StatusCode)
	}

	f, err := os.Create(destPath)
	if err != nil {
		return fmt.Errorf("failed to create file: %w", err)
	}
	defer func() {
		if err := f.Close(); err != nil {
			logMessage("ERROR", "Failed to close file: %v", err)
		}
	}()

	type copyResult struct {
		written int64
		err     error
	}
	resultChan := make(chan copyResult, 1)

	go func() {
		written, err := io.Copy(f, resp.Body)
		resultChan <- copyResult{written, err}
	}()

	select {
	case <-ctx.Done():
		return fmt.Errorf("download interrupted: %w", ctx.Err())
	case result := <-resultChan:
		if result.err != nil {
			return fmt.Errorf("failed to write file: %w", result.err)
		}
	}

	return nil
}

func validateChecksum(ctx context.Context, filePath, checksumsPath string) error {
	filename := filepath.Base(filePath)
	logMessage("INFO", "Validating checksum for %s...", filename)

	select {
	case <-ctx.Done():
		return fmt.Errorf("checksum validation cancelled: %w", ctx.Err())
	default:
	}

	if _, err := os.Stat(checksumsPath); os.IsNotExist(err) {
		logMessage("INFO", "Checksums file not found, skipping validation")
		return nil
	}

	expectedChecksum, err := findChecksumForFile(checksumsPath, filename)
	if err != nil {
		logMessage("INFO", "Checksum entry not found for %s, skipping validation", filename)
		return nil
	}

	actualChecksum, err := computeSHA256(ctx, filePath)
	if err != nil {
		return fmt.Errorf("failed to compute checksum: %w", err)
	}

	if !strings.EqualFold(expectedChecksum, actualChecksum) {
		logMessage("ERROR", "Checksum validation failed for %s", filename)
		logMessage("ERROR", "Expected: %s", expectedChecksum)
		logMessage("ERROR", "Actual: %s", actualChecksum)
		return fmt.Errorf("checksum mismatch")
	}

	logMessage("INFO", "[OK] Checksum validated for %s", filename)
	return nil
}

func findChecksumForFile(checksumsPath, filename string) (string, error) {
	f, err := os.Open(checksumsPath)
	if err != nil {
		return "", err
	}
	defer func() {
		if err := f.Close(); err != nil {
			logMessage("ERROR", "Failed to close checksums file: %v", err)
		}
	}()

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := scanner.Text()
		if strings.Contains(line, filename) {
			fields := strings.Fields(line)
			if len(fields) >= 1 {
				return fields[0], nil
			}
		}
	}

	if err := scanner.Err(); err != nil {
		return "", err
	}

	return "", fmt.Errorf("checksum not found for %s", filename)
}

func computeSHA256(ctx context.Context, filePath string) (string, error) {
	f, err := os.Open(filePath)
	if err != nil {
		return "", err
	}
	defer func() {
		if err := f.Close(); err != nil {
			logMessage("ERROR", "Failed to close file: %v", err)
		}
	}()

	h := sha256.New()

	type hashResult struct {
		written int64
		err     error
	}
	resultChan := make(chan hashResult, 1)

	go func() {
		written, err := io.Copy(h, f)
		resultChan <- hashResult{written, err}
	}()

	select {
	case <-ctx.Done():
		return "", fmt.Errorf("hash computation cancelled: %w", ctx.Err())
	case result := <-resultChan:
		if result.err != nil {
			return "", result.err
		}
	}

	return hex.EncodeToString(h.Sum(nil)), nil
}

func installBinary(ctx context.Context, sourcePath string) error {
	logMessage("INFO", "Installing %s to %s...", binaryName, installDir)

	select {
	case <-ctx.Done():
		return fmt.Errorf("installation cancelled: %w", ctx.Err())
	default:
	}

	if err := os.MkdirAll(installDir, 0755); err != nil {
		return fmt.Errorf("failed to create install directory: %w", err)
	}

	destPath := filepath.Join(installDir, binaryName)

	src, err := os.Open(sourcePath)
	if err != nil {
		return fmt.Errorf("failed to open source file: %w", err)
	}
	defer func() {
		if err := src.Close(); err != nil {
			logMessage("ERROR", "Failed to close source file: %v", err)
		}
	}()

	dst, err := os.Create(destPath)
	if err != nil {
		return fmt.Errorf("failed to create destination file: %w", err)
	}
	defer func() {
		if err := dst.Close(); err != nil {
			logMessage("ERROR", "Failed to close destination file: %v", err)
		}
	}()

	type copyResult struct {
		written int64
		err     error
	}
	resultChan := make(chan copyResult, 1)

	go func() {
		written, err := io.Copy(dst, src)
		resultChan <- copyResult{written, err}
	}()

	select {
	case <-ctx.Done():
		return fmt.Errorf("installation cancelled: %w", ctx.Err())
	case result := <-resultChan:
		if result.err != nil {
			return fmt.Errorf("failed to copy binary: %w", result.err)
		}
	}

	if _, err := os.Stat(destPath); os.IsNotExist(err) {
		logMessage("ERROR", "Failed to copy binary to %s", installDir)
		return fmt.Errorf("installation failed")
	}

	logMessage("INFO", "[OK] Installed %s to %s", binaryName, destPath)
	return nil
}

func updatePath(ctx context.Context) error {
	logMessage("INFO", "Updating PATH configuration...")

	select {
	case <-ctx.Done():
		return fmt.Errorf("PATH update cancelled: %w", ctx.Err())
	default:
	}

	cmd := exec.CommandContext(ctx, "reg", "query", "HKCU\\Environment", "/v", "Path")
	output, err := cmd.Output()

	var currentPath string
	if err == nil {
		lines := strings.Split(string(output), "\n")
		for _, line := range lines {
			if strings.Contains(line, "REG_") {
				parts := strings.SplitN(line, "REG_EXPAND_SZ", 2)
				if len(parts) < 2 {
					parts = strings.SplitN(line, "REG_SZ", 2)
				}
				if len(parts) >= 2 {
					currentPath = strings.TrimSpace(parts[1])
				}
			}
		}
	}

	pathParts := strings.Split(currentPath, ";")
	for _, p := range pathParts {
		if strings.EqualFold(strings.TrimSpace(p), installDir) {
			logMessage("INFO", "[OK] %s already in PATH", installDir)
			return nil
		}
	}

	var newPath string
	if currentPath != "" {
		newPath = currentPath + ";" + installDir
	} else {
		newPath = installDir
	}

	cmd = exec.CommandContext(ctx, "reg", "add", "HKCU\\Environment", "/v", "Path", "/t", "REG_EXPAND_SZ", "/d", newPath, "/f")
	if err := cmd.Run(); err != nil {
		if ctx.Err() != nil {
			return fmt.Errorf("PATH update cancelled: %w", ctx.Err())
		}
		logMessage("ERROR", "Failed to update PATH: %v", err)
		return fmt.Errorf("failed to update PATH: %w", err)
	}

	logMessage("INFO", "[OK] Added %s to user PATH", installDir)
	logMessage("INFO", "Note: Restart your terminal for PATH changes to take effect in new sessions")

	return nil
}

func registerCollector(ctx context.Context, token string) error {
	binaryPath := filepath.Join(installDir, binaryName)

	logMessage("INFO", "Registering collector...")

	select {
	case <-ctx.Done():
		return fmt.Errorf("registration cancelled: %w", ctx.Err())
	default:
	}

	if _, err := os.Stat(binaryPath); os.IsNotExist(err) {
		logMessage("ERROR", "Binary not found at %s", binaryPath)
		return fmt.Errorf("registration failed: binary not found")
	}

	var cmd *exec.Cmd
	if token != "" {
		cmd = exec.CommandContext(ctx, binaryPath, "-t", token)
	} else {
		cmd = exec.CommandContext(ctx, binaryPath)
	}

	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.Stdin = os.Stdin

	errChan := make(chan error, 1)
	go func() {
		errChan <- cmd.Run()
	}()

	select {
	case <-ctx.Done():
		if cmd.Process != nil {
			logMessage("INFO", "Terminating registration process due to cancellation...")
			if err := cmd.Process.Kill(); err != nil {
				logMessage("ERROR", "Failed to kill registration process: %v", err)
			}
		}
		return fmt.Errorf("registration cancelled: %w", ctx.Err())
	case err := <-errChan:
		if err != nil {
			if exitErr, ok := err.(*exec.ExitError); ok {
				logMessage("ERROR", "Registration failed with exit code %d", exitErr.ExitCode())
			} else {
				logMessage("ERROR", "Registration failed: %v", err)
			}
			return fmt.Errorf("registration failed")
		}
	}

	logMessage("INFO", "[OK] Collector registered successfully")
	return nil
}
