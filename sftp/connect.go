package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"errors"
	"fmt"
	"net"
	"os"
	"strconv"
	"time"

	"github.com/pkg/sftp"
	"golang.org/x/crypto/ssh"
	"golang.org/x/crypto/ssh/agent"
	"golang.org/x/crypto/ssh/knownhosts"
)

// handshakeTimeout bounds connecting, the SSH handshake, authentication and
// the start of the SFTP subsystem. ssh.ClientConfig.Timeout covers only the TCP
// connect, so a peer that accepts and never sends a banner would hang the run.
const handshakeTimeout = 30 * time.Second

// connect opens an SSH connection with strict host key checking and starts
// the SFTP subsystem on it. A shell or exec permission is not needed. The
// returned watchdog closes the connection when the source stops answering.
func connect(config Config, sftpTimeout time.Duration, logger func(string, ...interface{})) (*ssh.Client, *sftp.Client, *sftpWatchdog, error) {
	if config.KnownHosts == "" {
		return nil, nil, nil, errors.New("known-hosts: no file given; host keys are always verified")
	}
	hostKeyCallback, err := knownhosts.New(config.KnownHosts)
	if err != nil {
		return nil, nil, nil, fmt.Errorf("could not read known_hosts: %v", err)
	}
	auth, err := authMethods(config.SFTPKey)
	if err != nil {
		return nil, nil, nil, err
	}
	address := net.JoinHostPort(config.SFTPHost, strconv.Itoa(config.SFTPPort))
	sshConfig := &ssh.ClientConfig{
		User:              config.SFTPUser,
		Auth:              auth,
		HostKeyCallback:   hostKeyCallback,
		HostKeyAlgorithms: knownHostKeyAlgorithms(hostKeyCallback, address),
		Timeout:           handshakeTimeout,
	}
	conn, err := net.DialTimeout("tcp", address, handshakeTimeout)
	if err != nil {
		return nil, nil, nil, fmt.Errorf("could not connect to %s: %v", address, err)
	}
	if err := conn.SetDeadline(time.Now().Add(handshakeTimeout)); err != nil {
		conn.Close()
		return nil, nil, nil, fmt.Errorf("could not connect to %s: %v", address, err)
	}
	clientConn, channels, requests, err := ssh.NewClientConn(conn, address, sshConfig)
	if err != nil {
		conn.Close()
		return nil, nil, nil, fmt.Errorf("could not connect to %s: %v", address, err)
	}
	sshClient := ssh.NewClient(clientConn, channels, requests)
	watchdog := newSFTPWatchdog(sftpTimeout, func() {
		logger("The source did not answer an SFTP request for %v; closing the connection", sftpTimeout)
		sshClient.Close()
	})
	sftpClient, err := startSFTP(sshClient, watchdog)
	if err != nil {
		watchdog.Stop()
		sshClient.Close()
		return nil, nil, nil, fmt.Errorf("could not start SFTP on %s (is the sftp subsystem enabled?): %v", address, err)
	}
	if err := conn.SetDeadline(time.Time{}); err != nil {
		watchdog.Stop()
		sshClient.Close()
		return nil, nil, nil, fmt.Errorf("could not connect to %s: %v", address, err)
	}
	return sshClient, sftpClient, watchdog, nil
}

// startSFTP starts the SFTP subsystem like sftp.NewClient, but reads the
// answers through the watchdog. Output on stderr is discarded.
func startSFTP(sshClient *ssh.Client, watchdog *sftpWatchdog) (*sftp.Client, error) {
	session, err := sshClient.NewSession()
	if err != nil {
		return nil, err
	}
	input, err := session.StdinPipe()
	if err != nil {
		return nil, err
	}
	output, err := session.StdoutPipe()
	if err != nil {
		return nil, err
	}
	if err := session.RequestSubsystem("sftp"); err != nil {
		return nil, err
	}
	return sftp.NewClientPipe(watchdog.reader(output), input)
}

func authMethods(keyFile string) ([]ssh.AuthMethod, error) {
	if keyFile != "" {
		key, err := os.ReadFile(keyFile)
		if err != nil {
			return nil, fmt.Errorf("could not read key: %v", err)
		}
		signer, err := ssh.ParsePrivateKey(key)
		if err != nil {
			return nil, fmt.Errorf("could not parse key %s (use ssh-agent for passphrase-protected keys): %v", keyFile, err)
		}
		return []ssh.AuthMethod{ssh.PublicKeys(signer)}, nil
	}
	socket := os.Getenv("SSH_AUTH_SOCK")
	if socket == "" {
		return nil, errors.New("no --sftp-key given and SSH_AUTH_SOCK is not set")
	}
	conn, err := net.Dial("unix", socket)
	if err != nil {
		return nil, fmt.Errorf("could not reach ssh-agent: %v", err)
	}
	return []ssh.AuthMethod{ssh.PublicKeysCallback(agent.NewClient(conn).Signers)}, nil
}

// knownHostKeyAlgorithms returns the host key algorithms that known_hosts
// holds for address. Asking the server for exactly those keeps the handshake
// from negotiating another of the server's keys and failing although a valid
// key is on file. It probes the callback with a throwaway key: the resulting
// KeyError lists the keys on file.
func knownHostKeyAlgorithms(callback ssh.HostKeyCallback, address string) []string {
	public, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return nil
	}
	probe, err := ssh.NewPublicKey(public)
	if err != nil {
		return nil
	}
	var keyErr *knownhosts.KeyError
	if !errors.As(callback(address, &net.TCPAddr{IP: net.IPv4zero}, probe), &keyErr) {
		return nil
	}
	var algorithms []string
	for _, known := range keyErr.Want {
		if known.Key.Type() == ssh.KeyAlgoRSA {
			algorithms = append(algorithms, ssh.KeyAlgoRSASHA512, ssh.KeyAlgoRSASHA256, ssh.KeyAlgoRSA)
		} else {
			algorithms = append(algorithms, known.Key.Type())
		}
	}
	return algorithms
}
