package lm

import (
	"errors"
	"net"
	"net/url"
	"os"
	"syscall"
	"testing"
)

func TestWrapEndpointErrorConnectionRefused(t *testing.T) {
	inner := &url.Error{
		Op:  "Post",
		URL: "http://localhost:1234/v1/chat/completions",
		Err: &net.OpError{
			Op:  "dial",
			Err: &os.SyscallError{Syscall: "connect", Err: syscall.ECONNREFUSED},
		},
	}

	err := wrapEndpointError("http://localhost:1234/v1/chat/completions", inner)
	var unreachable *EndpointUnreachableError
	if !errors.As(err, &unreachable) {
		t.Fatalf("expected EndpointUnreachableError, got %T %v", err, err)
	}
	if unreachable.Endpoint != "http://localhost:1234/v1/chat/completions" {
		t.Fatalf("endpoint mismatch: %s", unreachable.Endpoint)
	}
	if !errors.Is(err, ErrEndpointUnreachable) {
		t.Fatalf("errors.Is should match ErrEndpointUnreachable")
	}
}

func TestWrapEndpointErrorPassthrough(t *testing.T) {
	inner := errors.New("some other failure")
	err := wrapEndpointError("http://localhost:1234/v1/chat/completions", inner)
	if errors.Is(err, ErrEndpointUnreachable) {
		t.Fatalf("passthrough error should not be treated as endpoint unreachable")
	}
	if err.Error() != "send request: some other failure" {
		t.Fatalf("unexpected error message: %v", err)
	}
}
