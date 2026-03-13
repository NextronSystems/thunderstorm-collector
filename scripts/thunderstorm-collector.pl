#!/usr/bin/perl
#
# THOR Thunderstorm Collector
# Florian Roth
# v0.2
# September 2025
#
# Requires LWP::UserAgent
#   - on Linux: apt-get install libwww-perl
#   - other: perl -MCPAN -e 'install Bundle::LWP'
#
# Usage examples:
#   $> perl thunderstorm-collector.pl -s thunderstorm.internal.net
#   $> perl thunderstorm-collector.pl --dir / --server thunderstorm.internal.net
#   $> perl thunderstorm-collector.pl --dir / --server thunderstorm.internal.net --source "My Source"

use warnings;
use strict;
use Getopt::Long;
use LWP::UserAgent;
use File::Spec::Functions qw( catfile );
use Sys::Hostname;
use POSIX qw(strftime);

use Cwd; # module for finding the current working directory

# Configuration
our $debug = 0;
my $targetdir = "/";
my $server = "";
my $port = 8080;
my $scheme = "http";
my $source = "";
my $ssl = 0;
my $insecure = 0;
my $ca_cert = "";
my $sync_mode = 0;
my $dry_run = 0;
my $retries_opt = 3;
my $progress_opt;       # undef = auto-detect, 1 = force on, 0 = force off
our $max_age = 14;      # in days (harmonized with bash/ash)
our $max_size_kb = 2048; # in KB (harmonized with bash/ash)
our $interrupted = 0;
# Note: size checks use $max_size_kb directly (in KB)
our @skipElements = map { qr{$_} } ('^\/proc', '^\/mnt', '\.dat$', '\.npm');
our @hardSkips = ('/proc', '/dev', '/sys', '/run', '/snap', '/.snapshots');

# Network and special filesystem types (mount points with these types are excluded)
our %networkFsTypes = map { $_ => 1 } qw(nfs nfs4 cifs smbfs smb3 sshfs fuse.sshfs afp webdav davfs2 fuse.rclone fuse.s3fs);
our %specialFsTypes = map { $_ => 1 } qw(proc procfs sysfs devtmpfs devpts cgroup cgroup2 pstore bpf tracefs debugfs securityfs hugetlbfs mqueue autofs fusectl rpc_pipefs nsfs configfs binfmt_misc selinuxfs efivarfs ramfs);

# Cloud storage folder names (lowercase)
our %cloudDirNames = map { $_ => 1 } ('onedrive', 'dropbox', '.dropbox', 'googledrive', 'google drive',
    'icloud drive', 'iclouddrive', 'nextcloud', 'owncloud', 'mega', 'megasync', 'tresorit', 'syncthing');

sub get_excluded_mounts {
    my @excluded;
    if (open(my $fh, '<', '/proc/mounts')) {
        while (my $line = <$fh>) {
            my @parts = split(/\s+/, $line);
            if (scalar @parts >= 3) {
                my ($mount_point, $fs_type) = ($parts[1], $parts[2]);
                if ($networkFsTypes{$fs_type} || $specialFsTypes{$fs_type}) {
                    push @excluded, $mount_point;
                }
            }
        }
        close($fh);
    }
    return @excluded;
}

sub is_cloud_path {
    my ($path) = @_;
    my $lower = lc($path);
    $lower =~ s/\\/\//g;
    my @segments = split(/\//, $lower);
    for my $seg (@segments) {
        return 1 if $cloudDirNames{$seg};
        return 1 if ($seg =~ /^onedrive[\s-]/ || $seg =~ /^nextcloud-/);
    }
    return 1 if ($lower =~ /\/library\/cloudstorage/);
    return 0;
}

# Command Line Parameters
GetOptions(
    "dir|d=s"        => \$targetdir,    # --dir or -d
    "server|s=s"     => \$server,       # --server or -s
    "port|p=i"       => \$port,         # --port or -p
    "source=s"       => \$source,       # --source (no short option to avoid conflict)
    "ssl"            => \$ssl,          # --ssl (use HTTPS)
    "insecure|k"     => \$insecure,     # --insecure or -k (skip TLS verify)
    "ca-cert=s"      => \$ca_cert,      # --ca-cert PATH (custom CA bundle)
    "sync"           => \$sync_mode,    # --sync (use /api/check)
    "dry-run"        => \$dry_run,      # --dry-run
    "retries=i"      => \$retries_opt,  # --retries N
    "max-age=i"      => \$max_age,      # --max-age N (days)
    "max-size-kb=i"  => \$max_size_kb,  # --max-size-kb N
    "progress"       => sub { $progress_opt = 1; },   # --progress
    "no-progress"    => sub { $progress_opt = 0; },   # --no-progress
    "debug"          => \$debug         # --debug
);
$scheme = "https" if $ssl;

# Validate numeric options
if ($retries_opt < 0) {
    print STDERR "[ERROR] --retries must be non-negative (got $retries_opt)\n";
    exit 2;
}
if ($max_age < 0) {
    print STDERR "[ERROR] --max-age must be non-negative (got $max_age)\n";
    exit 2;
}
if ($max_size_kb < 0) {
    print STDERR "[ERROR] --max-size-kb must be non-negative (got $max_size_kb)\n";
    exit 2;
}

# Progress reporting: auto-detect TTY unless overridden
our $show_progress;
if (defined $progress_opt) {
    $show_progress = $progress_opt;
} else {
    $show_progress = (-t STDERR) ? 1 : 0;
}

# Use Hostname as Source if not set
if ( $source eq "" ) {
    $source = hostname;
}
# Preserve raw source for use in collection markers
our $source_raw = $source;

# URL-encode source parameter
sub urlencode {
    my $s = shift;
    $s =~ s/([^A-Za-z0-9\-_.~])/sprintf("%%%02X", ord($1))/ge;
    return $s;
}

# Track whether URL has query parameters
our $url_has_query = 0;

# Add Source to URL if available
my $source_query = "";
if ( $source ne "" ) {
    print "[DEBUG] Using source identifier: $source\n" if $debug;
    $source_query = "?source=" . urlencode($source);
    $url_has_query = 1;
}

# Composed Values
our $base_url = "$scheme://$server:$port";
my $api_path = $sync_mode ? "/api/check" : "/api/checkAsync";
our $api_endpoint = "$base_url$api_path$source_query";
our $current_date = time;
our $SCAN_ID = "";

# Stats
our $num_submitted = 0;
our $num_processed = 0;
our $num_failed = 0;
our $collection_started = 0;

# Objects
our $ua;

# Properly escape a string for JSON (control chars, backslashes, quotes)
sub json_escape {
    my ($s) = @_;
    $s =~ s/\\/\\\\/g;
    $s =~ s/"/\\"/g;
    $s =~ s/\n/\\n/g;
    $s =~ s/\r/\\r/g;
    $s =~ s/\t/\\t/g;
    $s =~ s/\x08/\\b/g;
    $s =~ s/\x0c/\\f/g;
    # Escape remaining control characters (U+0000 to U+001F)
    $s =~ s/([\x00-\x1f])/sprintf("\\u%04x", ord($1))/ge;
    return $s;
}

# Send a begin/end collection marker to /api/collection
# Returns ($scan_id, $http_success) where:
#   $scan_id = scan_id from response or ""
#   $http_success = 1 if HTTP request succeeded, 0 if transport/HTTP failure
sub collection_marker {
    my ($marker_type, $scan_id, $stats_ref) = @_;
    my $marker_url = "$base_url/api/collection";
    $marker_url .= "?source=" . urlencode($source_raw) if $source_raw ne "";

    my $timestamp = POSIX::strftime("%Y-%m-%dT%H:%M:%SZ", gmtime());
    my $timestamp_esc = json_escape($timestamp);
    # Use the preserved raw source value (user-provided or hostname)
    my $src_escaped = json_escape($source_raw);

    my $type_esc = json_escape($marker_type);
    my $body = "{\"type\":\"$type_esc\",\"source\":\"$src_escaped\",\"collector\":\"perl/0.2\",\"timestamp\":\"$timestamp_esc\"";
    $body .= ",\"scan_id\":\"" . json_escape($scan_id) . "\"" if (defined $scan_id && $scan_id ne '');
    if ($stats_ref) {
        $body .= ",\"stats\":{";
        my @pairs;
        for my $k (keys %$stats_ref) {
            my $ek = json_escape($k);
            my $v = $stats_ref->{$k};
            if (defined $v && $v =~ /^-?\d+(?:\.\d+)?$/) {
                push @pairs, qq{"$ek":$v};
            } else {
                my $ev = json_escape(defined $v ? $v : "");
                push @pairs, qq{"$ek":"$ev"};
            }
        }
        $body .= join(",", @pairs) . "}";
    }
    $body .= "}";

    my $resp = eval {
        $ua->post($marker_url,
            "Content-Type" => "application/json",
            Content => $body,
        );
    };
    return ("", 0) unless $resp;
    # 404/501 = endpoint not supported, continue without scan_id but success
    if ($resp->code == 404 || $resp->code == 501) {
        print STDERR "[WARN] Collection marker '$marker_type' not supported (HTTP " . $resp->code . ") — server does not implement /api/collection\n";
        return ("", 1);
    }
    return ("", 0) unless $resp->is_success;

    my $resp_body = $resp->content;
    my $returned_id = "";
    # Parse scan_id from JSON, handling escaped characters
    if ($resp_body =~ /"scan_id"\s*:\s*"((?:[^"\\]|\\.)*)"/) {
        my $raw_id = $1;
        # Unescape JSON string escapes
        $raw_id =~ s/\\(["\\\/])/$1/g;
        $raw_id =~ s/\\n/\n/g;
        $raw_id =~ s/\\r/\r/g;
        $raw_id =~ s/\\t/\t/g;
        $raw_id =~ s/\\u([0-9a-fA-F]{4})/chr(hex($1))/ge;
        # Validate: scan_id should be alphanumeric/dash/underscore/dot (reject suspicious values)
        if ($raw_id =~ /^[A-Za-z0-9\-_.]+$/) {
            $returned_id = $raw_id;
        } else {
            print STDERR "[WARN] Received scan_id with unexpected characters, ignoring\n";
        }
    }
    return ($returned_id, 1);
}

# Count eligible files in a directory tree (for progress reporting)
our $total_eligible = 0;

sub is_hard_skip {
    my ($path) = @_;
    foreach (@hardSkips) {
        if ($path eq $_ || (index($path, $_) == 0 && substr($path, length($_), 1) eq '/')) {
            return 1;
        }
    }
    return 0;
}

sub countDir {
    my ($start) = @_;
    my @stack = ($start);

    while (@stack) {
        last if $interrupted;
        my $workdir = pop @stack;

        opendir(my $dh, $workdir) or next;
        my @names = readdir($dh);
        closedir($dh);

        foreach my $name (@names) {
            next if ($name eq "." || $name eq "..");
            last if $interrupted;

            my $filepath = catfile($workdir, $name);
            # Hard directory skips
            next if is_hard_skip($filepath);
            next if is_cloud_path($filepath);

            # Use lstat consistently to avoid following symlinks (mirrors processDir)
            my @st = lstat($filepath);
            next unless @st;
            # Skip symlinks
            next if -l _;

            if (-d _) {
                push @stack, $filepath;
                next;
            }

            # Only process regular files
            next unless -f _;

            my $size = $st[7];
            my $mdate = $st[9];

            # Apply same skip logic as processDir
            my $skipRegex = 0;
            foreach (@skipElements) {
                if ($filepath =~ $_) { $skipRegex = 1; last; }
            }
            next if $skipRegex;
            next if (defined $size && ($size / 1024) > $max_size_kb);
            next if (defined $mdate && $mdate < ($current_date - ($max_age * 86400)));

            $total_eligible++;
        }
    }
}

# Process Folders (iterative to avoid stack overflow on deep trees)
sub processDir {
    my ($start) = @_;
    my @stack = ($start);

    while (@stack) {
        last if $interrupted;
        my $workdir = pop @stack;

        opendir(my $dh, $workdir) or do { print STDERR "[ERROR] Unable to open $workdir:$!\n"; next; };

        my @names = readdir($dh);
        closedir($dh);

        next if !@names;

        foreach my $name (@names){
            next if ($name eq ".");
            next if ($name eq "..");

            # Check for interruption
            last if $interrupted;

            my $filepath = catfile($workdir, $name);
            # Hard directory skips (prefix match)
            next if is_hard_skip($filepath);

            # Skip cloud storage paths
            next if is_cloud_path($filepath);

            # Use lstat to avoid following symlinks; use _ for cached results
            my @st = lstat($filepath);
            next unless @st;  # skip if stat fails

            # Check symlinks using cached lstat result
            next if -l _;

            # Is a Directory
            if (-d _){
                push @stack, $filepath;
                next;
            }

            # Only process regular files
            next unless -f _;

            # Is a file
            if ( $debug ) { print "[DEBUG] Checking $filepath ...\n"; }

            my $size = $st[7];
            my $mdate = $st[9];

            # Skip some files ----------------------------------------
            # Skip Folders / elements
            my $skipRegex = 0;
            # Regex Checks
            foreach ( @skipElements ) {
                if ( $filepath =~ $_ ) {
                    if ( $debug ) { print "[DEBUG] Skipping file due to configured exclusion $filepath\n"; }
                    $skipRegex = 1;
                }
            }
            next if $skipRegex;
            # Size
            if ( defined $size && ( $size / 1024 ) > $max_size_kb ) {
                if ( $debug ) { print "[DEBUG] Skipping file due to file size $filepath\n"; }
                next;
            }
            # Age
            if ( defined $mdate && $mdate < ( $current_date - ($max_age * 86400) ) ) {
                if ( $debug ) { print "[DEBUG] Skipping file due to age $filepath\n"; }
                next;
            }

            # Count (after all skip checks, so only eligible files are counted)
            $num_processed++;

            # Progress reporting with [N/total] X% format
            if ($show_progress) {
                if ($total_eligible > 0) {
                    my $pct = int(($num_processed / $total_eligible) * 100);
                    $pct = 100 if $pct > 100;
                    print STDERR "\r[$num_processed/$total_eligible] $pct%   ";
                } else {
                    print STDERR "\r[PROGRESS] Processed: $num_processed Submitted: $num_submitted   ";
                }
            }

            # Submit
            &submitSample($filepath);
        }
    }
}

sub submitSample {
    my ($filepath) = shift;
    if ($dry_run) {
        print "[DRY-RUN] Would submit $filepath ...\n";
        $num_submitted++;
        return;
    }
    print STDERR "[SUBMIT] Submitting $filepath ...\n";
    my $retry = 0;
    my $successful = 0;
    my $next_sleep = 0;  # sleep time before next attempt (0 = no sleep for first attempt)
    for ($retry = 0; $retry <= $retries_opt; $retry++) {
        if ($next_sleep > 0) {
            print STDERR "[SUBMIT] Waiting $next_sleep seconds to retry submitting $filepath ...\n";
            sleep($next_sleep);
        }
        $successful = 0;
        $next_sleep = 0;
        eval {
            # Sanitize filename metadata: encode to UTF-8 with replacement, strip control chars
        my $safe_path = $filepath;
        if ($] >= 5.008) {
            require Encode;
            # Decode byte string as UTF-8, replacing invalid sequences
            $safe_path = Encode::decode('UTF-8', $safe_path, Encode::FB_DEFAULT());
            $safe_path = Encode::encode('UTF-8', $safe_path);
        }
        # Remove control characters except tab
        $safe_path =~ s/[\x00-\x08\x0b\x0c\x0e-\x1f]//g;
        my $req = $ua->post($api_endpoint,
                Content_Type => 'form-data',
                Content => [
                    # Preserve full client path in multipart filename for parity with other collectors
                    "file" => [ $filepath, $safe_path ],
                    "filename" => $safe_path,
                ],
            );
            $successful = $req->is_success;
            if (!$successful) {
                if ($req->code == 503) {
                    my $retry_after = 30;
                    my $ra = $req->header('Retry-After');
                    if (defined $ra && $ra =~ /^\d+$/) {
                        $retry_after = int($ra);
                        $retry_after = 300 if $retry_after > 300;  # cap at 5 minutes
                    }
                    $next_sleep = $retry_after;
                    print STDERR "[SUBMIT] Server busy (503), retrying in ${retry_after}s ...\n";
                } else {
                    # Exponential backoff for non-503 errors: 2, 4, 8, 16, ...
                    my $backoff = 2 ** ($retry + 1);
                    $backoff = 300 if $backoff > 300;
                    $next_sleep = $backoff;
                    print STDERR "[ERROR] Upload failed for '$filepath': ", $req->status_line, "\n";
                }
            }
            1;  # Return truthy so the 'or do { }' block doesn't execute on success
        } or do {
            my $error = $@ || 'Unknown failure';
            print STDERR "[ERROR] Could not submit '$filepath' - $error\n";
            # Exponential backoff on exception
            my $backoff = 2 ** ($retry + 1);
            $backoff = 300 if $backoff > 300;
            $next_sleep = $backoff;
        };
        if ($successful) {
            $num_submitted++;
            last;
        }
    }
    my $total_attempts = $retries_opt + 1;
    if (!$successful) {
        $num_failed++;
        print STDERR "[ERROR] Failed to submit '$filepath' after $total_attempts attempts\n";
    }
}

# MAIN ----------------------------------------------------------------
# Default Values
print STDERR "==============================================================\n";
print STDERR "    ________                __            __                  \n";
print STDERR "   /_  __/ /  __ _____  ___/ /__ _______ / /____  ______ _    \n";
print STDERR "    / / / _ \\/ // / _ \\/ _  / -_) __(_--/ __/ _ \\/ __/  ' \\   \n";
print STDERR "   /_/ /_//_/\\_,_/_//_/\\_,_/\\__/_/ /___/\\__/\\___/_/ /_/_/_/   \n";
print STDERR "                                                              \n";
print STDERR "   Florian Roth, Nextron Systems GmbH, 2021                   \n";
print STDERR "                                                              \n";
print STDERR "==============================================================\n";
if ($server eq "") {
    print STDERR "[ERROR] No Thunderstorm server specified. Use --server or -s.\n";
    exit 2;
}
# Validate server as hostname, IPv4, or bracketed IPv6 — reject URI delimiters
if ($server !~ /^(?:\[[0-9a-fA-F:]+\]|[A-Za-z0-9](?:[A-Za-z0-9\-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9\-]*[A-Za-z0-9])?)*)$/) {
    print STDERR "[ERROR] Invalid server value '$server'. Must be a hostname, IPv4 address, or bracketed IPv6 address.\n";
    exit 2;
}
print STDERR "Target Directory: '$targetdir'\n";
print STDERR "Thunderstorm Server: '$server'\n";
print STDERR "Thunderstorm Port: '$port'\n";
print STDERR "Using API Endpoint: $api_endpoint\n";
print STDERR "Maximum Age of Files: $max_age days\n";
print STDERR "Maximum File Size: $max_size_kb KB\n";
print STDERR "\n";

# Extend hardSkips with mount points of network/special filesystems
{
    my %seen = map { $_ => 1 } @hardSkips;
    for my $mp (get_excluded_mounts()) {
        push @hardSkips, $mp unless $seen{$mp}++;
    }
}

# Auto-enable SSL if TLS options specified without --ssl
if (!$ssl && ($ca_cert ne "" || $insecure)) {
    print STDERR "[WARN] TLS option specified without --ssl, auto-enabling SSL\n";
    $ssl = 1;
    $scheme = "https";
    $base_url = "$scheme://$server:$port";
    $api_endpoint = "$base_url$api_path$source_query";
}

# Instantiate an object
$ua = LWP::UserAgent->new;
if ($ssl) {
    if ($insecure) {
        $ua->ssl_opts(verify_hostname => 0, SSL_verify_mode => 0x00);
    } elsif ($ca_cert ne "") {
        if (! -f $ca_cert) {
            print STDERR "[ERROR] CA certificate file not found: $ca_cert\n";
            exit 2;
        }
        $ua->ssl_opts(SSL_ca_file => $ca_cert);
    }
}

# Signal handling: set flag only (async-signal-safe), defer network I/O to main loop
$SIG{INT} = $SIG{TERM} = sub {
    my $sig = shift;
    $interrupted = 1;
    print STDERR "\n[WARN] Caught SIG$sig, will send interrupted collection marker and exit ...\n";
};

# Pre-scan to count eligible files for progress reporting
if ($show_progress) {
    print STDERR "[INFO] Counting eligible files for progress reporting ...\n";
    countDir($targetdir);
    print STDERR "[INFO] Found $total_eligible eligible files\n" if !$interrupted;
}

print STDERR "Starting the walk at: $targetdir ...\n";

# Send collection begin marker (with single retry after 2s on failure)
my ($begin_id, $begin_ok) = collection_marker("begin", "", undef);
if (!$begin_ok) {
    print STDERR "[WARN] Initial connection to collection API failed, retrying in 2s ...\n";
    sleep(2);
    ($begin_id, $begin_ok) = collection_marker("begin", "", undef);
}
if (!$begin_ok) {
    print STDERR "[ERROR] Cannot connect to Thunderstorm server at $base_url/api/collection after retry. Aborting.\n";
    exit 2;
}
$collection_started = 1;
$SCAN_ID = $begin_id;
if ($SCAN_ID) {
    print STDERR "[INFO] Collection scan_id: $SCAN_ID\n";
    # Determine separator based on whether URL already has query params
    my $sep = $url_has_query ? "&" : "?";
    $api_endpoint .= "${sep}scan_id=" . urlencode($SCAN_ID);
    $url_has_query = 1;
}

# Start the walk
&processDir($targetdir);

# If interrupted, send interrupted marker and exit from normal execution context
if ($interrupted) {
    if ($collection_started) {
        my $int_date = time;
        my $int_elapsed = $int_date - $current_date;
        my ($int_id, $int_ok) = eval {
            collection_marker("interrupted", $SCAN_ID, {
                scanned  => $num_processed,
                submitted => $num_submitted,
                failed   => $num_failed,
                elapsed_seconds => $int_elapsed,
            });
        };
    if (!$int_ok) {
        print STDERR "[ERROR] Failed to send interrupted collection marker\n";
    }
    }
    # Clear progress line if we were showing progress
    if ($show_progress) {
        print STDERR "\r" . (" " x 60) . "\r";
    }
    my $int_minutes = int((time - $current_date) / 60);
    print STDERR "Thunderstorm Collector Run interrupted (Checked: $num_processed Submitted: $num_submitted Failed: $num_failed Minutes: $int_minutes)\n";
    exit 1;
}

# Send collection end marker with stats
my $end_date = time;
my $elapsed = $end_date - $current_date;
my $marker_failed = 0;
my ($end_id, $end_ok) = collection_marker("end", $SCAN_ID, {
    scanned  => $num_processed,
    submitted => $num_submitted,
    failed   => $num_failed,
    elapsed_seconds => $elapsed,
});
if (!$end_ok) {
    print STDERR "[ERROR] Failed to send end collection marker\n";
    $marker_failed = 1;
}

# Clear progress line if we were showing progress
if ($show_progress) {
    print STDERR "\r" . (" " x 60) . "\r";
}

my $minutes = int( $elapsed / 60 );
print STDERR "Thunderstorm Collector Run finished (Checked: $num_processed Submitted: $num_submitted Failed: $num_failed Minutes: $minutes)\n";

# Exit codes: 0 = success, 1 = partial failure, 2 = fatal error
if ($num_failed > 0 || $marker_failed) {
    exit 1;
}
exit 0;
