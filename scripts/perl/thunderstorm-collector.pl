#!/usr/bin/env perl
# THOR Thunderstorm Collector - Florian Roth / Nextron Systems
use 5.008001;
use strict;
use warnings;
use Getopt::Long qw(GetOptions Configure);
use LWP::UserAgent 6;
use HTTP::Request;
use JSON::PP;
use Encode qw(encode decode FB_DEFAULT);
use Cwd qw(abs_path);
use File::Spec;
use Fcntl qw(:DEFAULT :mode);
use Sys::Hostname qw(hostname);
use POSIX qw(strftime);

my (@dirs, $server, $source, $ca);
my ($port, $age, $size, $retries) = (8080, 14, 2048, 3);
my ($tls, $insecure, $sync, $dry, $debug, $help) = (0) x 6;
my $progress = -t STDERR ? 1 : 0;
Configure(qw(no_auto_abbrev no_ignore_case));
GetOptions(
    'dir|d=s' => \@dirs, 'server|s=s' => \$server, 'port|p=i' => \$port,
    'source=s' => \$source, 'ssl|tls' => \$tls, 'insecure|k' => \$insecure,
    'ca-cert=s' => \$ca, 'sync' => \$sync, 'dry-run' => \$dry,
    'max-age=i' => \$age, 'max-size-kb=i' => \$size, 'retries=i' => \$retries,
    'progress' => sub { $progress = 1 }, 'no-progress' => sub { $progress = 0 },
    'debug' => \$debug, 'help|h' => \$help
) or exit 2;
if ($help) {
    print "Usage: perl thunderstorm-collector.pl --server HOST --port 8080 --dir PATH\n",
          "Repeat --dir; --max-age 0 disables age filtering; --max-size-kb uses KiB.\n",
          "--source TEXT --ssl [--ca-cert FILE|--insecure] --sync --dry-run --retries 1..10\n";
    exit 0;
}
sub config_error { print STDERR "[ERROR] $_[0]\n"; exit 2 }
config_error('Unknown positional arguments') if @ARGV;
config_error('Server must be a DNS/IPv4 name or bracketed IPv6 address')
    unless defined $server && $server =~ /^(?:[A-Za-z0-9][A-Za-z0-9.-]*|\[[0-9a-fA-F:]+\])$/;
config_error('port 1..65535, age 0..36500, size 1..204800 KiB, retries 1..10 required')
    unless $port >= 1 && $port <= 65535 && $age >= 0 && $age <= 36500 &&
           $size >= 1 && $size <= 204800 && $retries >= 1 && $retries <= 10;
config_error('--ca-cert/--insecure require --ssl') if !$tls && ($ca || $insecure);
config_error('CA certificate file not found') if $ca && !-f $ca;
$source = decode('UTF-8', defined $source ? $source : hostname(), FB_DEFAULT);
@dirs = ('/') unless @dirs;
my $base = ($tls ? 'https' : 'http') . "://$server:$port";
my $json = JSON::PP->new->utf8->allow_nonref;
my ($scanned, $submitted, $failed, $skipped, $scan_errors) = (0) x 5;
my ($interrupted, $started, $scan_id) = (0, 0, '');
my $start = time;
my @excluded = qw(/proc /dev /sys /run /snap /.snapshots);
my %special = map { $_ => 1 } qw(nfs nfs4 cifs smbfs smb3 sshfs fuse.sshfs afp
    webdav davfs2 fuse.rclone fuse.s3fs proc procfs sysfs devtmpfs devpts cgroup
    cgroup2 pstore bpf tracefs debugfs securityfs hugetlbfs mqueue autofs fusectl
    rpc_pipefs nsfs configfs binfmt_misc selinuxfs efivarfs);
if (open my $mounts, '<', '/proc/mounts') {
    while (<$mounts>) {
        my @fields = split;
        next unless @fields >= 3 && $special{$fields[2]};
        my $path = $fields[1];
        $path =~ s/\\([0-7]{3})/chr(oct($1))/ge;
        push @excluded, $path;
    }
    close $mounts;
}
my $ua = LWP::UserAgent->new(timeout => 30, max_size => 1024 * 1024,
                            max_redirect => 0, requests_redirectable => [],
                            protocols_allowed => ['http', 'https']);
if ($tls) {
    eval { require LWP::Protocol::https; require IO::Socket::SSL; 1 }
        or config_error('HTTPS requires LWP::Protocol::https and IO::Socket::SSL');
    $ua->ssl_opts(verify_hostname => $insecure ? 0 : 1,
                  SSL_verify_mode => $insecure ? 0 : 1);
    $ua->ssl_opts(SSL_ca_file => $ca) if $ca;
}
$SIG{INT} = $SIG{TERM} = sub { $interrupted = 1 };

sub url_encode {
    my $bytes = encode('UTF-8', $_[0]);
    $bytes =~ s/([^A-Za-z0-9_.~-])/sprintf("%%%02X", ord($1))/ge;
    return $bytes;
}
sub excluded {
    my ($path) = @_;
    for my $root (@excluded) {
        return 1 if $path eq $root || index($path, "$root/") == 0;
    }
    my $lower = lc $path;
    $lower =~ s{\\}{/}g;
    return 1 if $lower =~ m{/library/cloudstorage(?:/|$)};
    for my $part (split m{/}, $lower) {
        return 1 if $part =~ /^(?:onedrive|dropbox|\.dropbox|googledrive|google drive|icloud drive|iclouddrive|nextcloud|owncloud|mega|megasync|tresorit|tresorit drive|syncthing)$/;
        return 1 if $part =~ /^(?:onedrive[ -]|nextcloud-)/;
    }
    return 0;
}
sub stats {
    return {scanned => $scanned, submitted => $submitted, failed => $failed,
            skipped => $skipped, scan_errors => $scan_errors, elapsed_seconds => time - $start};
}
sub request {
    my ($url, $content_type, $body, $timeout) = @_;
    my $req = HTTP::Request->new(POST => $url);
    $req->header('Content-Type' => $content_type, 'Content-Length' => length($body));
    $req->content($body);
    my $old_timeout = $ua->timeout;
    $ua->timeout($timeout);
    my $resp = eval { $ua->request($req) };
    my $error = $@;
    $ua->timeout($old_timeout);
    die $error if $error;
    die "No HTTP response\n" unless $resp;
    die "Transport aborted\n" if $resp->header('Client-Aborted') || $resp->header('X-Died') ||
        ($resp->header('Client-Warning') || '') =~ /Internal response/;
    my $length = $resp->header('Content-Length');
    die "Incomplete/invalid response length\n"
        if defined $length && ($length !~ /^\d+$/ || length($resp->content) != $length);
    return $resp;
}
sub marker {
    my ($kind) = @_;
    return 1 if $dry;
    my $body = {type => $kind, source => $source, hostname => decode('UTF-8', hostname(), FB_DEFAULT),
                collector => 'perl/0.3', timestamp => strftime('%Y-%m-%dT%H:%M:%SZ', gmtime)};
    $body->{scan_id} = $scan_id if length $scan_id;
    $body->{stats} = stats() unless $kind eq 'begin';
    for my $attempt (1 .. ($kind eq 'begin' ? 2 : 1)) {
        last if $interrupted && $kind ne 'interrupted';
        my $resp = eval { request("$base/api/collection", 'application/json', $json->encode($body), 10) };
        if ($resp && ($resp->code == 404 || $resp->code == 501)) {
            print STDERR "[WARN] Collection markers unsupported (HTTP ", $resp->code, ")\n";
            return 1;
        }
        if ($resp && $resp->is_success) {
            if ($kind eq 'begin') {
                my $data = eval { $json->decode($resp->content) };
                $scan_id = $data->{scan_id} if ref($data) eq 'HASH' &&
                    defined $data->{scan_id} && !ref($data->{scan_id});
            }
            return 1;
        }
        print STDERR "[ERROR] Collection $kind: ", $@ || ($resp ? $resp->status_line : 'no response'), "\n";
        sleep 2 if $kind eq 'begin' && $attempt == 1 && !$interrupted;
    }
    return 0;
}
sub eligible {
    my ($metadata) = @_;
    return $metadata->[7] <= $size * 1024 && (!$age || $metadata->[9] >= $start - $age * 86400);
}
sub snapshot {
    my ($path, $expected) = @_;
    my $flags = O_RDONLY | O_NONBLOCK;
    $flags |= eval { Fcntl::O_NOFOLLOW() } || 0;
    sysopen(my $file, $path, $flags) or die "open: $!\n";
    binmode $file;
    my @before = stat $file;
    die "File replaced or no longer regular\n" unless @before && S_ISREG($before[2]) &&
        $before[0] == $expected->[0] && $before[1] == $expected->[1];
    if (!eligible(\@before)) { close $file; return undef }
    my $data = '';
    while (length($data) <= $size * 1024) {
        my $remaining = $size * 1024 + 1 - length($data);
        my $count = sysread($file, my $chunk, $remaining < 65536 ? $remaining : 65536);
        die "read: $!\n" unless defined $count;
        last unless $count;
        $data .= $chunk;
        die "Interrupted while reading\n" if $interrupted;
    }
    my @after = stat $file;
    close $file or die "close: $!\n";
    die "File changed while reading\n" unless @after && length($data) == $before[7] &&
        $before[7] == $after[7] && $before[9] == $after[9];
    return $data;
}
sub upload {
    my ($path, $metadata) = @_;
    if ($dry) { print "[DRY-RUN] Would submit $path\n"; $submitted++; return }
    my $data = eval { snapshot($path, $metadata) };
    if ($@) { print STDERR "[ERROR] Cannot read $path: $@"; $failed++; return }
    if (!defined $data) { $skipped++; return }
    my $filename = $path;
    $filename =~ s/[\\";\r\n\t\x00]/_/g;
    $filename = encode('UTF-8', decode('UTF-8', $filename, FB_DEFAULT));
    my $boundary = 'thunderstorm-' . $$ . '-' . time . '-' . int(rand(1_000_000_000));
    my $body = "--$boundary\r\nContent-Disposition: form-data; name=\"file\"; filename=\"$filename\"\r\n" .
               "Content-Type: application/octet-stream\r\n\r\n" . $data . "\r\n--$boundary--\r\n";
    my $endpoint = $base . ($sync ? '/api/check' : '/api/checkAsync') . '?source=' . url_encode($source);
    $endpoint .= '&scan_id=' . url_encode($scan_id) if length $scan_id;
    for my $attempt (1 .. $retries) {
        last if $interrupted;
        my $resp = eval { request($endpoint, "multipart/form-data; boundary=$boundary", $body, 30) };
        if ($resp && $resp->is_success) { $submitted++; return }
        print STDERR "[ERROR] Upload $path: ", $@ || ($resp ? $resp->status_line : 'no response'), "\n";
        my $delay = 2 ** ($attempt - 1);
        $delay = 60 if $delay > 60;
        if ($resp && $resp->code == 503) {
            my $value = $resp->header('Retry-After');
            $delay = defined $value && $value =~ /^\d+$/ ? ($value > 120 ? 120 : $value) : 2;
        }
        sleep $delay if $attempt < $retries && !$interrupted;
    }
    $failed++;
}
sub walk {
    my ($root) = @_;
    my @stack = ($root);
    while (@stack && !$interrupted) {
        my $directory = pop @stack;
        next if excluded($directory);
        opendir(my $handle, $directory) or do {
            print STDERR "[ERROR] Cannot traverse $directory: $!\n"; $scan_errors++; next;
        };
        $! = 0;
        my @names = readdir $handle;
        my $read_error = 0 + $!;
        my $closed = closedir $handle;
        if ($read_error || !$closed) { print STDERR "[ERROR] Directory read failed: $directory\n"; $scan_errors++ }
        for my $name (@names) {
            last if $interrupted;
            next if $name eq '.' || $name eq '..';
            my $path = File::Spec->catfile($directory, $name);
            my @metadata = lstat $path;
            if (!@metadata) { print STDERR "[ERROR] Cannot stat $path: $!\n"; $failed++; next }
            next if S_ISLNK($metadata[2]);
            if (S_ISDIR($metadata[2])) { push @stack, $path unless excluded($path); next }
            next unless S_ISREG($metadata[2]);
            $scanned++;
            if ($path =~ m{^/mnt(?:/|$)|\.dat$|\.npm|\.lck$} || !eligible(\@metadata)) { $skipped++; next }
            upload($path, \@metadata);
            print STDERR "[$scanned examined]\n" if $progress;
        }
    }
}
my @roots;
for my $path (@dirs) {
    my $real = abs_path($path);
    if (!defined $real || !-d $real) { print STDERR "[ERROR] Missing directory $path\n"; $scan_errors++ }
    else { push @roots, $real }
}
exit 2 unless @roots;
my $begin_ok = marker('begin');
exit 1 if $interrupted;
exit 2 unless $begin_ok;
$started = 1;
walk($_) for @roots;
if ($interrupted) {
    $SIG{INT} = $SIG{TERM} = 'IGNORE';
    marker('interrupted') if $started && !$dry;
    print STDERR "Thunderstorm Collector Run interrupted\n";
    exit 1;
}
my $end_ok = marker('end');
print STDERR "Thunderstorm Collector Run finished (Checked: $scanned Submitted: $submitted Failed: $failed " .
             "Skipped: $skipped Scan errors: $scan_errors Seconds: " . (time - $start) . ")\n";
exit(($failed || $scan_errors || $interrupted || !$end_ok) ? 1 : 0);
