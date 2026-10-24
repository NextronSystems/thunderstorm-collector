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

// connect opens an SSH connection with strict host key checking and starts
// the SFTP subsystem on it. A shell or exec permission is not needed.
func connect(config Config) (*ssh.Client, *sftp.Client, error) {
	if config.KnownHosts == "" {
		return nil, nil, errors.New("known-hosts: no file given; host keys are always verified")
	}
	hostKeyCallback, err := knownhosts.New(config.KnownHosts)
	if err != nil {
		return nil, nil, fmt.Errorf("could not read known_hosts: %v", err)
	}
	auth, err := authMethods(config.SFTPKey)
	if err != nil {
		return nil, nil, err
	}
	address := net.JoinHostPort(config.SFTPHost, strconv.Itoa(config.SFTPPort))
	sshConfig := &ssh.ClientConfig{
		User:              config.SFTPUser,
		Auth:              auth,
		HostKeyCallback:   hostKeyCallback,
		HostKeyAlgorithms: knownHostKeyAlgorithms(hostKeyCallback, address),
		Timeout:           30 * time.Second,
	}
	sshClient, err := ssh.Dial("tcp", address, sshConfig)
	if err != nil {
		return nil, nil, fmt.Errorf("could not connect to %s: %v", address, err)
	}
	sftpClient, err := sftp.NewClient(sshClient)
	if err != nil {
		sshClient.Close()
		return nil, nil, fmt.Errorf("could not start SFTP on %s (is the sftp subsystem enabled?): %v", address, err)
	}
	return sshClient, sftpClient, nil
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
