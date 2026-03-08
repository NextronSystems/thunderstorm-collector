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
my $log_file = "";
my $sync_mode = 0;
my $dry_run = 0;
my $retries_opt = 3;
our $max_age = 14;      # in days (harmonized with bash/ash)
our $max_size_kb = 2048; # in KB (harmonized with bash/ash)
# Note: size checks use $max_size_kb directly (in KB)
our @skipElements = map { qr{$_} } ('^\/proc', '^\/mnt', '\.dat$', '\.npm');
our @hardSkips = ('/proc', '/dev', '/sys', '/run', '/snap', '/.snapshots');

# Network and special filesystem types (mount points with these types are excluded)
our %networkFsTypes = map { $_ => 1 } qw(nfs nfs4 cifs smbfs smb3 sshfs fuse.sshfs afp webdav davfs2 fuse.rclone fuse.s3fs);
our %specialFsTypes = map { $_ => 1 } qw(proc procfs sysfs devtmpfs devpts cgroup cgroup2 pstore bpf tracefs debugfs securityfs hugetlbfs mqueue autofs fusectl rpc_pipefs nsfs configfs binfmt_misc selinuxfs efivarfs ramfs);

# Cloud storage folder names (lowercase)
our %cloudDirNames = map { $_ => 1 } ('onedrive', 'dropbox', '.dropbox', 'googledrive', 'google drive',
    'icloud drive', 'iclouddrive', 'nextcloud', 'owncloud', 'mega', 'megasync', 'tresorit', 'syncthing');

sub unescape_octal {
    # Decode \040-style octal escapes in /proc/mounts fields
    my ($s) = @_;
    $s =~ s/\\([0-7]{3})/chr(oct($1))/ge;
    return $s;
}

sub get_excluded_mounts {
    my @excluded;
    if (open(my $fh, '<', '/proc/mounts')) {
        while (my $line = <$fh>) {
            my @parts = split(/\s+/, $line);
            if (scalar @parts >= 3) {
                my $mount_point = unescape_octal($parts[1]);
                my $fs_type = $parts[2];
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
my $progress_opt;  # undef=auto, 1=force on, 0=force off
GetOptions(
    "dir|d=s"        => \$targetdir,    # --dir or -d
    "server|s=s"     => \$server,       # --server or -s
    "port|p=i"       => \$port,         # --port or -p
    "source=s"       => \$source,       # --source (no short option to avoid conflict)
    "ssl"            => \$ssl,          # --ssl (use HTTPS)
    "insecure|k"     => \$insecure,     # --insecure or -k (skip TLS verify)
    "ca-cert=s"      => \$ca_cert,      # --ca-cert FILE (custom CA bundle)
    "log-file=s"     => \$log_file,     # --log-file FILE (log to file)
    "sync"           => \$sync_mode,    # --sync (use /api/check)
    "dry-run"        => \$dry_run,      # --dry-run
    "retries=i"      => \$retries_opt,  # --retries N
    "max-age=i"      => \$max_age,      # --max-age N (days)
    "max-size-kb=i"  => \$max_size_kb,  # --max-size-kb N
    "debug"          => \$debug,        # --debug
    "progress"       => sub { $progress_opt = 1 },  # --progress
    "no-progress"    => sub { $progress_opt = 0 },  # --no-progress
);
$scheme = "https" if $ssl;

# Validate required parameters
if ( $server eq "" ) {
    print STDERR "[ERROR] --server is required. Use --server <host> to specify the Thunderstorm server.\n";
    exit 2;
}

# Use Hostname as Source if not set
if ( $source eq "" ) {
    $source = hostname;
}
# URL-encode source parameter
sub urlencode {
    my $s = shift;
    $s =~ s/([^A-Za-z0-9\-_.~])/sprintf("%%%02X", ord($1))/ge;
    return $s;
}

# Keep original source name for collection markers; build query string separately
our $source_name = $source;
my $query_source = "";
if ( $source ne "" ) {
    print "[DEBUG] Using source identifier: $source\n" if $debug;
    $query_source = "?source=" . urlencode($source);
}

# Composed Values
our $base_url = "$scheme://$server:$port";
my $api_path = $sync_mode ? "/api/check" : "/api/checkAsync";
our $api_endpoint = "$base_url$api_path$query_source";
our $current_date = time;
our $SCAN_ID = "";

# Stats
our $num_submitted = 0;
our $num_processed = 0;
our $num_failed = 0;
our $num_total = 0;

# Progress reporting (declared early — referenced in GetOptions)
my $progress_enabled = 0;
my $progress_interval = 100;
my $progress_last_time = 0;
my $progress_time_interval = 10;

# Log file handle
my $log_fh;

sub write_log {
    my ($msg) = @_;
    return unless $log_fh;
    my $ts = strftime("%Y-%m-%d %H:%M:%S", localtime);
    print $log_fh "$ts $msg\n";
}

# Objects
our $ua;

# Send a begin/end collection marker to /api/collection
# Returns scan_id from response, or "" if unsupported/failed
sub json_escape_str {
    my ($s) = @_;
    $s =~ s/\\/\\\\/g;
    $s =~ s/"/\\"/g;
    $s =~ s/\n/\\n/g;
    $s =~ s/\r/\\r/g;
    $s =~ s/\t/\\t/g;
    # Escape remaining control characters (U+0000 to U+001F)
    $s =~ s/([\x00-\x1f])/sprintf("\\u%04x", ord($1))/ge;
    return $s;
}

sub collection_marker {
    my ($marker_type, $scan_id, $stats_ref, $reason) = @_;
    my $marker_url = "$base_url/api/collection";

    my $timestamp = POSIX::strftime("%Y-%m-%dT%H:%M:%SZ", gmtime());
    my $src_escaped = json_escape_str($source_name);

    my $body = "{\"type\":\"$marker_type\",\"source\":\"$src_escaped\",\"collector\":\"perl/0.2\",\"timestamp\":\"$timestamp\"";
    $body .= ",\"scan_id\":\"$scan_id\"" if $scan_id;
    if ($stats_ref) {
        $body .= ",\"stats\":{";
        my @pairs;
        for my $k (keys %$stats_ref) { push @pairs, "\"$k\":$stats_ref->{$k}"; }
        $body .= join(",", @pairs) . "}";
    }
    $body .= ",\"reason\":\"" . json_escape_str($reason) . "\"" if $reason;
    $body .= "}";

    my $resp = eval {
        $ua->post($marker_url,
            "Content-Type" => "application/json",
            Content => $body,
        );
    };
    return "" unless $resp && $resp->is_success;

    my $resp_body = $resp->content;
    my $returned_id = "";
    if ($resp_body =~ /"scan_id"\s*:\s*"([^"]+)"/) {
        $returned_id = $1;
    }
    return $returned_id;
}

# Progress reporting ----------------------------------------------------------
sub resolve_progress {
    if (defined $progress_opt) {
        $progress_enabled = $progress_opt;
    } else {
        $progress_enabled = (-t STDOUT) ? 1 : 0;
    }
}

sub count_files_recursive {
    my ($dir) = @_;
    my $count = 0;
    return 0 unless opendir(my $dh, $dir);
    my @entries = readdir($dh);
    closedir($dh);
    for my $name (@entries) {
        next if $name eq '.' || $name eq '..';
        my $path = catfile($dir, $name);
        next if -l $path;  # skip symlinks
        if (-d $path) {
            my $skip = 0;
            for (@hardSkips) { $skip = 1 if $path eq $_; }
            next if $skip;
            next if is_cloud_path($path);
            $count += count_files_recursive($path);
        } elsif (-f $path) {
            # Apply same regex exclusions as processDir for accurate count
            my $skipRegex = 0;
            for (@skipElements) { $skipRegex = 1 if $path =~ $_; }
            $count++ unless $skipRegex;
        }
    }
    return $count;
}

sub maybe_progress {
    return unless $progress_enabled;
    return unless $num_total > 0;
    my $do_report = 0;
    $do_report = 1 if ($num_processed % $progress_interval == 0);
    unless ($do_report) {
        my $now = time;
        if ($progress_last_time > 0 && ($now - $progress_last_time) >= $progress_time_interval) {
            $do_report = 1;
        }
    }
    return unless $do_report;
    $progress_last_time = time;
    my $pct = ($num_total > 0) ? int(($num_processed * 100) / $num_total) : 0;
    printf "[%d/%d] %d%% processed\n", $num_processed, $num_total, $pct;
}

# Process Folders
sub processDir {
    my ($workdir) = shift;
    my ($startdir) = &cwd;
    # keep track of where we began
    chdir($workdir) or do { print STDERR "[ERROR] Unable to enter dir $workdir:$!\n"; write_log("[ERROR] Unable to enter dir $workdir:$!"); return; };
    opendir(DIR, ".") or do { print STDERR "[ERROR] Unable to open $workdir:$!\n"; write_log("[ERROR] Unable to open $workdir:$!"); chdir($startdir); return; };

    my @names = readdir(DIR);
    closedir(DIR);

    foreach my $name (@names){
        next if ($name eq ".");
        next if ($name eq "..");

        #print("Workdir: $workdir Name: $name\n");
        my $filepath = catfile($workdir, $name);
        # Hard directory skips
        my $skipHard = 0;
        foreach ( @hardSkips ) {
            $skipHard = 1 if ( $filepath eq $_ );
        }
        next if $skipHard;

        # Skip symbolic links (check before -d/-f to avoid stat on stale targets)
        next if -l $filepath;

        # Skip cloud storage paths
        next if is_cloud_path($filepath);

        # Is a Directory
        if (-d $filepath){
            # Process Dir
            &processDir($filepath);
            next;
        }

        if ( $debug ) { print "[DEBUG] Checking $filepath ...\n"; }

        # Characteristics
        my @st = stat($filepath);
        unless (@st) {
            print STDERR "[ERROR] Cannot stat '$filepath': $!\n";
            write_log("[ERROR] Cannot stat '$filepath': $!");
            $num_failed++;
            next;
        }
        my $size = $st[7];
        my $mdate = $st[9];
        #print("SIZE: $size MDATE: $mdate\n");

        # Count
        $num_processed++;
        maybe_progress();

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
        if ( ( $size / 1024 ) > $max_size_kb ) {
            if ( $debug ) { print "[DEBUG] Skipping file due to file size $filepath\n"; }
            next;
        }
        # Age
        #print("MDATE: $mdate CURR_DATE: $current_date\n");
        if ( $mdate < ( $current_date - ($max_age * 86400) ) ) {
            if ( $debug ) { print "[DEBUG] Skipping file due to age $filepath\n"; }
            next;
        }

        # Submit
        &submitSample($filepath);

        chdir($startdir) or die "Unable to change back to dir $startdir:$!\n";
    }
}

sub submitSample {
    my ($filepath) = shift;
    if ($dry_run) {
        print "[DRY-RUN] Would submit $filepath ...\n";
        $num_submitted++;
        return;
    }
    print "[SUBMIT] Submitting $filepath ...\n";
    my $retry = 0;
    my $successful = 0;
    my $skip_backoff = 0;  # Set after 503 Retry-After sleep to avoid double-sleep
    for ($retry = 0; $retry < $retries_opt; $retry++) {
        if ($retry > 0 && !$skip_backoff) {
            my $sleep_time = 2 << $retry;
            print STDERR "[SUBMIT] Waiting $sleep_time seconds to retry submitting $filepath ...\n";
            write_log("[RETRY] Waiting $sleep_time seconds to retry $filepath");
            sleep($sleep_time)
        }
        $successful = 0;
        my $is_503 = 0;
        my $retry_after = 30;
        eval {
            my $req = $ua->post($api_endpoint,
                Content_Type => 'form-data',
                Content => [
                    # Second element overrides the filename sent in Content-Disposition
                    "file" => [ $filepath, $filepath ],
                ],
            );
            $successful = $req->is_success;
            if (!$successful) {
                if ($req->code == 503) {
                    $is_503 = 1;
                    my $ra = $req->header('Retry-After');
                    if (defined $ra && $ra =~ /^\d+$/) {
                        $retry_after = int($ra);
                    }
                    print STDERR "[SUBMIT] Server busy (503), retrying in ${retry_after}s ...\n";
                    write_log("[RETRY] Server busy (503), retrying in ${retry_after}s for $filepath");
                } else {
                    print STDERR "Error: ", $req->status_line, "\n";
                    write_log("[ERROR] " . $req->status_line . " for $filepath");
                }
            }
        } or do {
            my $error = $@ || 'Unknown failure';
            warn "Could not submit '$filepath' - $error";
            write_log("[ERROR] Could not submit '$filepath' - $error");
        };
        if ($successful) {
            $num_submitted++;
            last;
        }
        # For 503, use server-specified wait time INSTEAD of exponential backoff
        if ($is_503) {
            $retry_after = 300 if $retry_after > 300;  # Cap at 5 minutes
            sleep($retry_after);
            $retry++;       # Count 503 retries toward the limit
            $skip_backoff = 1;  # Already slept for Retry-After
            redo;
        }
        $skip_backoff = 0;
    }
    # If we never succeeded after all attempts
    unless ($successful) {
        print STDERR "[ERROR] Failed to submit '$filepath' after $retries_opt attempt(s)\n";
        write_log("[ERROR] Failed to submit '$filepath' after $retries_opt attempt(s)");
        $num_failed++;
    }
}

# MAIN ----------------------------------------------------------------
# Default Values
print "==============================================================\n";
print "    ________                __            __                  \n";
print "   /_  __/ /  __ _____  ___/ /__ _______ / /____  ______ _    \n";
print "    / / / _ \\/ // / _ \\/ _  / -_) __(_--/ __/ _ \\/ __/  ' \\   \n";
print "   /_/ /_//_/\\_,_/_//_/\\_,_/\\__/_/ /___/\\__/\\___/_/ /_/_/_/   \n";
print "                                                              \n";
print "   Florian Roth, Nextron Systems GmbH, 2021                   \n";
print "                                                              \n";
print "==============================================================\n";
print "Target Directory: '$targetdir'\n";
print "Thunderstorm Server: '$server'\n";
print "Thunderstorm Port: '$port'\n";
print "Using API Endpoint: $api_endpoint\n";
print "Maximum Age of Files: $max_age days\n";
print "Maximum File Size: $max_size_kb KB\n";
print "\n";

# Extend hardSkips with mount points of network/special filesystems
{
    my %seen = map { $_ => 1 } @hardSkips;
    for my $mp (get_excluded_mounts()) {
        push @hardSkips, $mp unless $seen{$mp}++;
    }
}

# Instantiate an object
$ua = LWP::UserAgent->new(timeout => 30);
if ($ssl && $insecure) {
    $ua->ssl_opts(verify_hostname => 0, SSL_verify_mode => 0x00);
} elsif ($ssl && $ca_cert) {
    die "[ERROR] CA certificate file not found: $ca_cert\n" unless -f $ca_cert;
    $ua->ssl_opts(SSL_ca_file => $ca_cert);
}

resolve_progress();

# Open log file if specified
if ($log_file) {
    open($log_fh, ">>", $log_file) or do {
        print STDERR "[ERROR] Cannot open log file '$log_file': $!\n";
        exit 2;
    };
    $log_fh->autoflush(1);
}

# Count files for progress reporting
if ($progress_enabled) {
    $num_total = count_files_recursive($targetdir);
    $progress_last_time = time();  # initialize so time-based trigger works even with < 100 files
    print "[INFO] Found $num_total files to process\n";
}

print "Starting the walk at: $targetdir ...\n";
write_log("[INFO] Starting the walk at: $targetdir");

# Send collection begin marker (retry once on failure)
$SCAN_ID = collection_marker("begin", "", undef);
if (!$SCAN_ID) {
    print STDERR "[WARN] Begin marker failed, retrying in 2s...\n";
    sleep(2);
    $SCAN_ID = collection_marker("begin", "", undef);
}
if ($SCAN_ID) {
    print "[INFO] Collection scan_id: $SCAN_ID\n";
    my $sep = ($api_endpoint =~ /\?/) ? "&" : "?";
    $api_endpoint .= "${sep}scan_id=" . urlencode($SCAN_ID);
}

# Register signal handlers for graceful interruption
my $handle_signal = sub {
    my $sig = shift;
    print "\n[WARN] Received SIG$sig — sending interrupted marker...\n";
    my $elapsed = time - $current_date;
    collection_marker("interrupted", $SCAN_ID, {
        scanned   => $num_processed,
        submitted => $num_submitted,
        failed    => $num_failed,
        elapsed_seconds => $elapsed,
    }, "signal");
    my $exit_code = ($sig eq 'INT') ? 130 : 143;
    exit $exit_code;
};
$SIG{INT}  = $handle_signal;
$SIG{TERM} = $handle_signal;

# Start the walk
&processDir($targetdir);

# Send collection end marker with stats
my $end_date = time;
my $elapsed = $end_date - $current_date;
collection_marker("end", $SCAN_ID, {
    scanned  => $num_processed,
    submitted => $num_submitted,
    failed   => $num_failed,
    elapsed_seconds => $elapsed,
});

my $minutes = int( $elapsed / 60 );
print "Thunderstorm Collector Run finished (Checked: $num_processed Submitted: $num_submitted Failed: $num_failed Minutes: $minutes)\n";
write_log("[INFO] Run finished: processed=$num_processed submitted=$num_submitted failed=$num_failed elapsed=${minutes}m");
close($log_fh) if $log_fh;

# Exit codes: 0=clean, 1=partial failure, 2=fatal
exit 1 if $num_failed > 0;
